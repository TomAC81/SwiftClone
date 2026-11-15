import SwiftUI
import AppKit
import SwiftCloneCore

struct DeletionPrompt: Identifiable {
    let id = UUID()
    let job: BackupJob
    let scan: ScanResult
}

struct AlertInfo {
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case jobs = "Backup Jobs", history = "History", settings = "Settings"
        var id: Section { self }
        var icon: String {
            switch self {
            case .jobs: "externaldrive.badge.timemachine"
            case .history: "clock.arrow.circlepath"
            case .settings: "gearshape"
            }
        }
    }

    @Published var section: Section? = .jobs
    @Published var jobs: [BackupJob] = [] {
        didSet {
            guard loaded, jobs != oldValue else { return }
            persistJobs()
            rescheduleTimer()
        }
    }
    @Published var history: [RunRecord] = []
    @Published var selectedJobID: UUID?
    /// Present for every job that is scanning or running.
    @Published var progress: [UUID: BackupProgress] = [:]
    @Published var paused: Set<UUID> = []
    @Published var deletionPrompt: DeletionPrompt?
    @Published var alert: AlertInfo?
    @Published var verboseLogging: Bool = UserDefaults.standard.bool(forKey: "verboseLogging") {
        didSet { UserDefaults.standard.set(verboseLogging, forKey: "verboseLogging") }
    }

    let store = Persistence(directory: Persistence.defaultDirectory)
    let logDirectory = Persistence.defaultLogDirectory
    private var loaded = false
    private var controls: [UUID: RunControl] = [:]

    // Scheduling state
    private var timer: Timer?
    private var lastScheduleCheck = Date()
    /// Scheduled runs skipped because source or destination wasn't there.
    private var missed: Set<UUID> = []
    /// Jobs whose paths were unavailable at the last look.
    private var unavailable: Set<UUID> = []

    init() {
        do {
            jobs = try store.loadJobs()
            history = try store.loadHistory()
        } catch {
            alert = AlertInfo(title: "Couldn't load saved jobs",
                              message: "The job database could not be read (\(error.localizedDescription)). It has not been changed.")
        }
        loaded = alert == nil   // never overwrite a database we failed to read
        selectedJobID = jobs.first?.id
        refreshAvailability()
        rescheduleTimer()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.volumeMounted() }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAvailability() }
        }
    }

    // MARK: Jobs

    func addJob() {
        let job = BackupJob(name: "Backup \(jobs.count + 1)")
        jobs.append(job)
        selectedJobID = job.id
        section = .jobs
    }

    func deleteJob(_ id: UUID) {
        guard !isRunning(id) else { return }
        jobs.removeAll { $0.id == id }
        if selectedJobID == id { selectedJobID = jobs.first?.id }
    }

    func binding(for id: UUID) -> Binding<BackupJob>? {
        guard jobs.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.jobs.first { $0.id == id } ?? BackupJob() },
            set: { new in if let i = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[i] = new } })
    }

    func lastRun(for id: UUID) -> RunRecord? { history.first { $0.jobID == id } }
    func isRunning(_ id: UUID) -> Bool { progress[id] != nil }
    func nextRun(for job: BackupJob) -> Date? { ScheduleCalculator.nextRun(after: Date(), schedule: job.schedule) }

    private func persistJobs() {
        do { try store.saveJobs(jobs) } catch {
            alert = AlertInfo(title: "Couldn't save jobs", message: error.localizedDescription)
        }
    }

    func chooseFolder(title: String, startingAt path: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = title
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: Running

    /// User pressed Start.
    func start(_ job: BackupJob) {
        guard !isRunning(job.id) else { return }
        if let issue = PathValidator.validate(source: job.sourcePath, destination: job.destinationPath).issues.first {
            alert = AlertInfo(title: "This backup can't start", message: issue.userMessage)
            return
        }
        if job.mode == .mirror { preview(job) } else { execute(job, approval: nil, prescan: nil) }
    }

    /// Mirror mode: scan first so the user sees what would be deleted.
    private func preview(_ job: BackupJob) {
        let control = begin(job.id)
        Task.detached { [self] in
            do {
                let scan = try await BackupEngine(job: job).scan(control: control) { p in
                    Task { @MainActor in self.report(p, for: job.id) }
                }
                await self.previewFinished(job, scan)
            } catch {
                await self.previewFailed(job, error)
            }
        }
    }

    private func previewFinished(_ job: BackupJob, _ scan: ScanResult) {
        end(job.id)
        if scan.deletions.isEmpty {
            execute(job, approval: nil, prescan: scan)
        } else {
            deletionPrompt = DeletionPrompt(job: job, scan: scan)
        }
    }

    private func previewFailed(_ job: BackupJob, _ error: Error) {
        end(job.id)
        if error is CancellationError { return }
        let message = (error as? EngineError)?.userMessage ?? error.localizedDescription
        alert = AlertInfo(title: "This backup can't start", message: message)
    }

    /// Answer to the deletion preview. `delete == false` copies without removing anything.
    func resolve(_ prompt: DeletionPrompt, delete: Bool) {
        deletionPrompt = nil
        execute(prompt.job, approval: delete ? DeletionApproval(approving: prompt.scan.deletions) : nil,
                prescan: prompt.scan)
    }

    private func execute(_ job: BackupJob, approval: DeletionApproval?, prescan: ScanResult?) {
        guard !isRunning(job.id) else { return }
        let control = begin(job.id)
        var engine = BackupEngine(job: job, logDirectory: logDirectory)
        engine.verboseLog = verboseLogging
        Task.detached { [self, engine] in
            let record = await engine.run(approval: approval, prescan: prescan, control: control) { p in
                Task { @MainActor in self.report(p, for: job.id) }
            }
            await self.finish(record)
        }
    }

    private func begin(_ id: UUID) -> RunControl {
        let control = RunControl()
        controls[id] = control
        progress[id] = BackupProgress()
        return control
    }

    private func end(_ id: UUID) {
        controls[id] = nil
        progress[id] = nil
        paused.remove(id)
    }

    private func report(_ p: BackupProgress, for id: UUID) {
        // Late updates can arrive after the run ended; don't resurrect it.
        if controls[id] != nil { progress[id] = p }
    }

    private func finish(_ record: RunRecord) {
        end(record.jobID)
        history.insert(record, at: 0)
        if history.count > Persistence.historyLimit { history.removeLast(history.count - Persistence.historyLimit) }
        try? store.saveHistory(history)
    }

    func cancel(_ id: UUID) { controls[id]?.cancel() }

    func togglePause(_ id: UUID) {
        guard let control = controls[id] else { return }
        if paused.contains(id) { control.resume(); paused.remove(id) } else { control.pause(); paused.insert(id) }
    }

    func clearHistory() {
        history = []
        try? store.saveHistory(history)
    }

    // MARK: Restore

    func restoreFiles(from job: BackupJob) {
        let pick = NSOpenPanel()
        pick.canChooseFiles = true
        pick.canChooseDirectories = true
        pick.allowsMultipleSelection = true
        pick.directoryURL = URL(fileURLWithPath: job.destinationPath)
        pick.prompt = "Restore"
        pick.message = "Choose the files or folders to restore from this backup."
        guard pick.runModal() == .OK, !pick.urls.isEmpty else { return }
        guard let target = chooseFolder(title: "Choose where to put the restored items. Existing files are never replaced.",
                                        startingAt: job.sourcePath) else { return }
        let items = pick.urls.map(\.path)
        Task.detached { [self] in
            let outcome: AlertInfo
            do {
                let created = try Restorer.restore(items: items, into: target)
                outcome = AlertInfo(title: "Restore complete",
                                    message: "\(created.count) item\(created.count == 1 ? "" : "s") restored to \(target).")
            } catch {
                outcome = AlertInfo(title: "Restore failed", message: error.localizedDescription)
            }
            await MainActor.run { self.alert = outcome }
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Scheduling
    //
    // One timer aimed at the soonest due job; no helper process. Schedules
    // therefore only fire while the app is open.

    private func rescheduleTimer() {
        timer?.invalidate()
        let upcoming = jobs.compactMap { ScheduleCalculator.nextRun(after: lastScheduleCheck, schedule: $0.schedule) }.min()
        guard let upcoming else { return }
        let interval = max(1, upcoming.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.timerFired() }
        }
    }

    private func timerFired() {
        let now = Date()
        for job in jobs {
            if let due = ScheduleCalculator.nextRun(after: lastScheduleCheck, schedule: job.schedule), due <= now {
                startUnattended(job)
            }
        }
        lastScheduleCheck = now
        rescheduleTimer()
    }

    /// Scheduled and on-mount runs. Nobody is there to confirm deletions, so
    /// none are approved: a mirror job copies and leaves extras in place.
    private func startUnattended(_ job: BackupJob) {
        guard !isRunning(job.id) else { return }
        guard PathValidator.validate(source: job.sourcePath, destination: job.destinationPath).isValid else {
            missed.insert(job.id)
            unavailable.insert(job.id)
            return
        }
        missed.remove(job.id)
        execute(job, approval: nil, prescan: nil)
    }

    private func isAvailable(_ job: BackupJob) -> Bool {
        FileManager.default.fileExists(atPath: job.sourcePath) && FileManager.default.fileExists(atPath: job.destinationPath)
    }

    private func refreshAvailability() {
        unavailable = Set(jobs.filter { !isAvailable($0) }.map(\.id))
    }

    private func volumeMounted() {
        // Only jobs whose drive just came back are considered, so mounting an
        // unrelated disk image doesn't start anything.
        for job in jobs where unavailable.contains(job.id) && isAvailable(job) {
            unavailable.remove(job.id)
            if missed.contains(job.id) || job.schedule.runWhenDestinationAppears { startUnattended(job) }
        }
    }
}
