import Foundation

// MARK: - Public types

public struct BackupProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case preparing, scanning, copying, verifying, finished }
    public var phase: Phase = .preparing
    public var filesTotal = 0
    public var filesDone = 0
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    public var currentPath = ""
    public var phaseStarted = Date()

    public init() {}

    /// 0…1 while copying or verifying, nil when the total isn't known yet.
    public var fraction: Double? {
        switch phase {
        case .copying:
            if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
            return filesTotal > 0 ? min(1, Double(filesDone) / Double(filesTotal)) : 1
        case .verifying:
            return filesTotal > 0 ? min(1, Double(filesDone) / Double(filesTotal)) : nil
        case .finished: return 1
        default: return nil
        }
    }

    public func estimatedSecondsRemaining(now: Date = Date()) -> TimeInterval? {
        guard let f = fraction, f > 0.02, f < 1 else { return nil }
        let elapsed = now.timeIntervalSince(phaseStarted)
        guard elapsed > 2 else { return nil }
        return elapsed * (1 - f) / f
    }
}

/// A destination item that mirror mode would remove.
public struct DeletionCandidate: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// Path relative to the destination root.
    public var path: String
    public var isDirectory: Bool
    /// Files affected (1 for a file, everything inside for a folder).
    public var fileCount: Int
    public var bytes: Int64
    /// Set when the item is removed to make room for a source item of another type.
    public var replacedByDifferentType: Bool
}

public struct ScanResult: Sendable, Equatable {
    public var filesToCopy = 0
    public var bytesToCopy: Int64 = 0
    public var filesUnchanged = 0
    public var deletions: [DeletionCandidate] = []
}

/// Permission to delete exactly these destination paths, and nothing else.
/// The only way mirror mode ever removes anything.
public struct DeletionApproval: Sendable, Equatable {
    public let paths: Set<String>
    public init(paths: Set<String>) { self.paths = paths }
    public init(approving candidates: [DeletionCandidate]) { paths = Set(candidates.map(\.path)) }
}

public enum EngineError: Error, Sendable, Equatable {
    case validation(ValidationIssue)
    case insufficientSpace(needed: Int64, available: Int64)
    case destinationUnavailable
    case destinationFull
    case sourceUnreadable(String)

    public var userMessage: String {
        switch self {
        case .validation(let issue): return issue.userMessage
        case .insufficientSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough space on the destination: \(f.string(fromByteCount: needed)) needed, \(f.string(fromByteCount: available)) free. Nothing was copied."
        case .destinationUnavailable:
            return "The destination drive was disconnected during the backup. Files copied so far are intact; reconnect the drive and run the backup again to continue."
        case .destinationFull:
            return "The destination ran out of space during the backup. Files copied so far are intact."
        case .sourceUnreadable(let detail):
            return "The source couldn't be read. \(detail)"
        }
    }
}

// MARK: - Engine

public struct BackupEngine: Sendable {
    public let job: BackupJob
    /// Free bytes at a path. Replaceable so tests can simulate a full disk.
    public var freeSpace: @Sendable (String) -> Int64? = { VolumeInfo(path: $0)?.availableBytes }
    /// Where run logs go; nil disables logging.
    public var logDirectory: URL?
    public var verboseLog = false

    /// Headroom required beyond the bytes to copy (filesystem metadata, temp files).
    static let spaceMargin: Int64 = 16 * 1024 * 1024
    static let maxRecordedErrors = 200

    public init(job: BackupJob, logDirectory: URL? = nil) {
        self.job = job
        self.logDirectory = logDirectory
    }

    private struct Context: Sendable {
        let source: String
        let destination: String
        let dryRun: Bool
        let approved: Set<String>
        let excluded: Set<String>
        let tolerance: Int64
        let destinationDevice: dev_t
        let sourceDevice: dev_t
        let state: RunState
        let control: RunControl
        let logger: RunLogger?
    }

    private func makeContext(dryRun: Bool, approval: DeletionApproval?, state: RunState,
                             control: RunControl, logger: RunLogger?) throws -> Context {
        let validation = PathValidator.validate(source: job.sourcePath, destination: job.destinationPath)
        if let issue = validation.issues.first { throw EngineError.validation(issue) }
        let source = PathValidator.resolved(job.sourcePath)
        let destination = PathValidator.resolved(job.destinationPath)
        var st = stat()
        guard stat(destination, &st) == 0 else { throw EngineError.destinationUnavailable }
        var sourceStat = stat()
        guard stat(source, &sourceStat) == 0 else { throw EngineError.validation(.sourceMissing) }
        let fsType = VolumeInfo(path: destination)?.filesystemType ?? ""
        return Context(source: source, destination: destination, dryRun: dryRun,
                       approved: approval?.paths ?? [], excluded: Set(job.excludedNames),
                       tolerance: ChangeDetector.mtimeTolerance(forFilesystem: fsType),
                       destinationDevice: st.st_dev, sourceDevice: sourceStat.st_dev, state: state, control: control, logger: logger)
    }

    /// Dry run: works out what a backup would do without writing anything.
    /// Use it to show the mirror-mode deletion preview.
    public func scan(control: RunControl = RunControl(),
                     progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) async throws -> ScanResult {
        let state = RunState(emit: progress)
        return try await scan(state: state, control: control, logger: nil)
    }

    private func scan(state: RunState, control: RunControl, logger: RunLogger?) async throws -> ScanResult {
        let context = try makeContext(dryRun: true, approval: nil, state: state, control: control, logger: logger)
        state.beginPhase(.scanning, filesTotal: 0, bytesTotal: 0)
        try await walk("", context)
        return state.scanResult()
    }

    /// Runs the backup and always returns a record describing what happened.
    /// - Parameters:
    ///   - approval: deletions the user confirmed. Without it nothing is deleted.
    ///   - prescan: result of a `scan` done moments ago, to avoid scanning twice.
    public func run(approval: DeletionApproval? = nil, prescan: ScanResult? = nil,
                    control: RunControl = RunControl(),
                    progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) async -> RunRecord {
        let started = Date()
        let logger = logDirectory.flatMap {
            RunLogger(directory: $0, jobName: job.name, date: started, verbose: verboseLog)
        }
        let state = RunState(emit: progress)
        var failure: EngineError?
        var unexpected: String?
        var verification: VerificationSummary?

        logger?.log(.info, "Job \"\(job.name)\" started. Mode: \(job.mode.rawValue). Source: \(job.sourcePath). Destination: \(job.destinationPath)")
        do {
            let plan: ScanResult
            if let prescan { plan = prescan } else { plan = try await scan(state: state, control: control, logger: logger) }
            logger?.log(.info, "Scan: \(plan.filesToCopy) files to copy (\(plan.bytesToCopy) bytes), \(plan.filesUnchanged) unchanged, \(plan.deletions.count) deletion candidates")

            let context = try makeContext(dryRun: false, approval: approval, state: state, control: control, logger: logger)
            if let available = freeSpace(context.destination) {
                let needed = plan.bytesToCopy + Self.spaceMargin
                if plan.bytesToCopy > 0 && needed > available {
                    throw EngineError.insufficientSpace(needed: needed, available: available)
                }
            }

            state.beginPhase(.copying, filesTotal: plan.filesToCopy, bytesTotal: plan.bytesToCopy)
            try await walk("", context)

            if job.verification != .none {
                state.beginPhase(.verifying, filesTotal: plan.filesToCopy + plan.filesUnchanged, bytesTotal: 0)
                verification = try await Verifier.verify(
                    source: context.source, destination: context.destination, mode: job.verification,
                    excluded: context.excluded, tolerance: context.tolerance, control: control,
                    onFile: { state.verified($0) },
                    onMismatch: { path, why in
                        state.recordError(path: path, message: why)
                        logger?.log(.error, "Verification: \(path): \(why)")
                    })
            }
        } catch let error as EngineError {
            failure = error
        } catch is CancellationError {
            // handled below via control.isCancelled / state.fatal
        } catch {
            unexpected = String(describing: error)
        }
        if let fatal = state.fatal { failure = fatal }

        let totals = state.totals()
        let status: RunStatus
        let summary: String
        if let failure {
            status = .failed
            summary = failure.userMessage
        } else if let unexpected {
            status = .failed
            summary = "The backup stopped because of an unexpected problem: \(unexpected)"
        } else if control.isCancelled {
            status = .cancelled
            summary = "Cancelled. Files copied before cancelling are intact; run the backup again to finish."
        } else if totals.errorCount > 0 {
            status = .completedWithErrors
            summary = "Finished, but \(totals.errorCount) item\(totals.errorCount == 1 ? "" : "s") had problems. See the error list."
        } else {
            status = .success
            summary = totals.filesCopied == 0 && totals.deleted == 0
                ? "Everything was already up to date."
                : "Backup completed."
        }

        var record = RunRecord(jobID: job.id, jobName: job.name, startedAt: started, finishedAt: Date(),
                               status: status, summary: summary)
        record.filesCopied = totals.filesCopied
        record.bytesTransferred = totals.bytesCopied
        record.filesUnchanged = totals.unchanged
        record.itemsDeleted = totals.deleted
        record.deletionsNotApproved = totals.deletionsNotApproved
        record.errorCount = totals.errorCount
        record.errors = totals.errors
        record.verification = verification
        record.logPath = logger?.url.path
        if totals.deletionsNotApproved > 0 {
            record.summary += " \(totals.deletionsNotApproved) item\(totals.deletionsNotApproved == 1 ? "" : "s") in the destination no longer exist in the source and were left in place."
        }

        logger?.log(status == .success ? .info : .warning,
                    "Finished: \(status.rawValue). Copied \(record.filesCopied) files, \(record.bytesTransferred) bytes. Deleted \(record.itemsDeleted). Errors \(record.errorCount). \(record.summary)")
        logger?.close()
        state.beginPhase(.finished, filesTotal: 0, bytesTotal: 0)
        return record
    }

    // MARK: Walk

    private func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a + "/" + b }

    private func destinationPresent(_ c: Context) -> Bool {
        var st = stat()
        return stat(c.destination, &st) == 0 && st.st_dev == c.destinationDevice
    }

    /// Visits one directory: diff, act, then recurse. Throws only for
    /// conditions that end the whole run; per-item problems are recorded.
    private func walk(_ rel: String, _ c: Context) async throws {
        await c.control.waitIfPaused()
        if c.control.isCancelled { throw CancellationError() }
        // If the drive was unplugged, /Volumes/Name is gone (or, worse, is now
        // a plain folder on another device). Stop before writing anything there.
        if !c.dryRun && !destinationPresent(c) {
            c.state.setFatal(.destinationUnavailable)
            throw EngineError.destinationUnavailable
        }

        let srcDir = rel.isEmpty ? c.source : c.source + "/" + rel
        let dstDir = rel.isEmpty ? c.destination : c.destination + "/" + rel

        // Stay on the source's own volume. A folder that is a mount point
        // (another disk, a network share, a disk image) is not descended
        // into: backing up "everything mounted below here" is never what a
        // folder backup means, and one of those mounts could be the destination.
        if !rel.isEmpty {
            var st = stat()
            if stat(srcDir, &st) == 0 && st.st_dev != c.sourceDevice {
                c.logger?.log(.info, "Skipped \(rel): it is a different volume mounted inside the source")
                return
            }
        }

        let sourceEntries: [FileEntry]
        do {
            sourceEntries = try DirectoryReader.list(srcDir)
        } catch let error as PosixError {
            if rel.isEmpty { throw EngineError.sourceUnreadable(error.userMessage) }
            c.state.recordError(path: rel, message: error.userMessage)
            c.logger?.log(.error, "\(rel): \(error)")
            return
        }
        // A folder that doesn't exist yet (dry run) simply has no entries.
        let destinationEntries = (try? DirectoryReader.list(dstDir)) ?? []

        let actions = BackupPlanner.plan(source: sourceEntries, destination: destinationEntries, mode: job.mode,
                                         toleranceNanos: c.tolerance, excludedNames: c.excluded)
        var copies: [FileEntry] = []
        var subdirectories: [String] = []

        if !c.dryRun {
            for stale in destinationEntries where BackupPlanner.isPartial(stale.name) && stale.kind != .directory {
                unlink(dstDir + "/" + stale.name)
                c.logger?.log(.info, "Removed leftover temporary file \(join(rel, stale.name))")
            }
        }

        for action in actions {
            switch action {
            case .skipUnchanged:
                c.state.unchanged()
            case .skipUnsupported(let e):
                c.logger?.detail("Skipped special file \(join(rel, e.name))")
            case .copy(let e, _):
                if c.dryRun { c.state.planned(bytes: e.size) } else { copies.append(e) }
            case .descend(let e):
                subdirectories.append(e.name)
            case .createDirectory(let e):
                if c.dryRun || makeDirectory(join(rel, e.name), c) { subdirectories.append(e.name) }
            case .delete(let d):
                handleDeletion(d, rel: join(rel, d.name), replacing: false, c)
            case .typeConflict(let s, let d):
                let path = join(rel, s.name)
                guard handleDeletion(d, rel: path, replacing: true, c) else {
                    if !c.dryRun {
                        let message = "The destination has a \(d.kind == .directory ? "folder" : "file") here but the source has a \(s.kind == .directory ? "folder" : "file"). It was left unchanged."
                        c.state.recordError(path: path, message: message)
                        c.logger?.log(.warning, "\(path): \(message)")
                    } else if s.kind == .directory {
                        subdirectories.append(s.name)   // count what would be copied
                    } else {
                        c.state.planned(bytes: s.size)
                    }
                    continue
                }
                if s.kind == .directory {
                    if makeDirectory(path, c) { subdirectories.append(s.name) }
                } else {
                    copies.append(s)
                }
            }
        }

        if !copies.isEmpty { await copyBatch(copies, rel: rel, c) }
        if c.control.isCancelled { throw CancellationError() }

        for name in subdirectories {
            try await walk(join(rel, name), c)
        }
        if !c.dryRun { FileCopier.copyDirectoryMetadata(from: srcDir, to: dstDir) }
    }

    private func makeDirectory(_ rel: String, _ c: Context) -> Bool {
        let path = c.destination + "/" + rel
        if mkdir(path, 0o700) == 0 || errno == EEXIST { return true }
        let error = PosixError(operation: "Creating folder", path: path)
        noteFailure(error, rel: rel, c)
        return false
    }

    /// Dry run: records the candidate. Real run: deletes only if this exact
    /// path was approved. Returns true if the item is gone afterwards.
    @discardableResult
    private func handleDeletion(_ d: FileEntry, rel: String, replacing: Bool, _ c: Context) -> Bool {
        let path = c.destination + "/" + rel
        // Never delete across a mount point: a volume mounted inside the
        // destination is not part of this backup.
        if d.kind == .directory {
            var st = stat()
            if lstat(path, &st) != 0 || st.st_dev != c.destinationDevice {
                if !c.dryRun {
                    c.state.recordError(path: rel, message: "This folder is a separate volume mounted inside the destination. It was left untouched.")
                }
                return false
            }
        }
        if c.dryRun {
            let stats = d.kind == .directory ? DirectoryReader.treeStats(path) : (files: 1, bytes: d.size)
            c.state.addCandidate(DeletionCandidate(path: rel, isDirectory: d.kind == .directory,
                                                   fileCount: stats.files, bytes: stats.bytes,
                                                   replacedByDifferentType: replacing))
            return false
        }
        guard c.approved.contains(rel) else {
            c.state.deletionNotApproved()
            c.logger?.log(.info, "Not deleted (no approval): \(rel)")
            return false
        }
        do {
            try Self.removeTree(path, kind: d.kind, device: c.destinationDevice)
            c.state.deleted()
            c.logger?.log(.delete, rel)
            return true
        } catch {
            let why = (error as? PosixError)?.userMessage ?? error.localizedDescription
            c.state.recordError(path: rel, message: "Couldn't delete: \(why)")
            c.logger?.log(.error, "Delete failed for \(rel): \(error)")
            return false
        }
    }

    /// Recursive delete that never follows symlinks and never leaves
    /// `device`. FileManager.removeItem would happily continue into a volume
    /// mounted somewhere below `path`.
    static func removeTree(_ path: String, kind: EntryKind, device: dev_t) throws {
        guard kind == .directory else {
            if unlink(path) != 0 && errno != ENOENT { throw PosixError(operation: "Deleting", path: path) }
            return
        }
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw PosixError(operation: "Deleting", path: path)
        }
        guard st.st_dev == device else { throw PosixError(code: EXDEV, operation: "Deleting", path: path) }
        for entry in try DirectoryReader.list(path) {
            try removeTree(path + "/" + entry.name, kind: entry.kind, device: device)
        }
        if rmdir(path) != 0 && errno != ENOENT { throw PosixError(operation: "Deleting", path: path) }
    }

    /// Copies a directory's files with a bounded number in flight.
    private func copyBatch(_ entries: [FileEntry], rel: String, _ c: Context) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = entries.makeIterator()
            var active = 0
            while true {
                while active < c.state.concurrencyLimit, !c.control.isCancelled, let entry = iterator.next() {
                    active += 1
                    group.addTask {
                        await c.control.waitIfPaused()
                        if !c.control.isCancelled { self.copyOne(entry, rel: self.join(rel, entry.name), c) }
                    }
                }
                if active == 0 { break }
                await group.next()
                active -= 1
            }
        }
    }

    private func copyOne(_ entry: FileEntry, rel: String, _ c: Context) {
        c.state.setCurrent(rel)
        do {
            try FileCopier.copy(from: c.source + "/" + rel, to: c.destination + "/" + rel, entry: entry,
                                shouldContinue: { !c.control.isCancelled },
                                onBytes: { c.state.addBytes($0) })
            c.state.fileCopied()
            c.logger?.detail("Copied \(rel)")
        } catch is CancellationError {
        } catch let error as PosixError {
            noteFailure(error, rel: rel, c)
        } catch {
            c.state.recordError(path: rel, message: error.localizedDescription)
        }
    }

    /// Decides whether a failure concerns one item or ends the run.
    private func noteFailure(_ error: PosixError, rel: String, _ c: Context) {
        c.logger?.log(.error, "\(rel): \(error) (errno \(error.code))")
        if error.code == ENOSPC || error.code == EDQUOT {
            c.state.setFatal(.destinationFull)
            c.control.cancel()
        } else if !destinationPresent(c) {
            c.state.setFatal(.destinationUnavailable)
            c.control.cancel()
        } else {
            c.state.recordError(path: rel, message: error.userMessage)
        }
    }
}

// MARK: - Shared run state

/// Counters shared by concurrent copy tasks. A lock rather than an actor:
/// updates come from inside copyfile's synchronous progress callback.
final class RunState: @unchecked Sendable {
    struct Totals {
        var filesCopied = 0, unchanged = 0, deleted = 0, deletionsNotApproved = 0, errorCount = 0
        var bytesCopied: Int64 = 0
        var errors: [RunError] = []
    }

    private let lock = NSLock()
    private let emit: @Sendable (BackupProgress) -> Void
    private var progress = BackupProgress()
    private var t = Totals()
    private var scan = ScanResult()
    private var lastEmit = Date.distantPast
    private var concurrency = AdaptiveConcurrency(maximum: min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)))
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    private var windowFiles = 0
    private var _fatal: EngineError?

    init(emit: @escaping @Sendable (BackupProgress) -> Void) { self.emit = emit }

    /// Runs `body` under the lock, then publishes progress at most 10×/s.
    private func update(force: Bool = false, _ body: () -> Void) {
        let snapshot: BackupProgress? = lock.withLock {
            body()
            let now = Date()
            guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return nil }
            lastEmit = now
            return progress
        }
        if let snapshot { emit(snapshot) }
    }

    var fatal: EngineError? { lock.withLock { _fatal } }
    func setFatal(_ e: EngineError) { lock.withLock { if _fatal == nil { _fatal = e } } }
    var concurrencyLimit: Int { lock.withLock { concurrency.limit } }
    func totals() -> Totals { lock.withLock { t } }
    func scanResult() -> ScanResult { lock.withLock { scan } }

    func beginPhase(_ phase: BackupProgress.Phase, filesTotal: Int, bytesTotal: Int64) {
        update(force: true) {
            progress = BackupProgress()
            progress.phase = phase
            progress.filesTotal = filesTotal
            progress.bytesTotal = bytesTotal
            windowStart = Date(); windowBytes = 0; windowFiles = 0
        }
    }

    // Scan phase
    func planned(bytes: Int64) {
        update { scan.filesToCopy += 1; scan.bytesToCopy += bytes; progress.filesDone += 1 }
    }
    func addCandidate(_ c: DeletionCandidate) { lock.withLock { scan.deletions.append(c) } }

    // Both phases
    func unchanged() {
        update {
            if progress.phase == .scanning { scan.filesUnchanged += 1; progress.filesDone += 1 } else { t.unchanged += 1 }
        }
    }

    // Copy phase
    func setCurrent(_ path: String) { update { progress.currentPath = path } }
    func addBytes(_ n: Int64) { update { t.bytesCopied += n; progress.bytesDone += n; windowBytes += n } }
    func fileCopied() {
        update {
            t.filesCopied += 1; progress.filesDone += 1; windowFiles += 1
            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= 1 {
                concurrency.record(bytes: windowBytes, files: windowFiles, seconds: elapsed)
                windowStart = Date(); windowBytes = 0; windowFiles = 0
            }
        }
    }
    func deleted() { lock.withLock { t.deleted += 1 } }
    func deletionNotApproved() { lock.withLock { t.deletionsNotApproved += 1 } }
    func recordError(path: String, message: String) {
        lock.withLock {
            t.errorCount += 1
            if t.errors.count < BackupEngine.maxRecordedErrors { t.errors.append(RunError(path: path, message: message)) }
        }
    }

    // Verify phase
    func verified(_ path: String) { update { progress.filesDone += 1; progress.currentPath = path } }
}
