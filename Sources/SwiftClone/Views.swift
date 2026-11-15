import SwiftUI
import SwiftCloneCore

// MARK: - Formatting

enum Format {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : (t >= 60 ? [.minute, .second] : [.second])
        return f.string(from: max(1, t)) ?? ""
    }

    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

extension RunStatus {
    var label: String {
        switch self {
        case .success: "Succeeded"
        case .completedWithErrors: "Finished with errors"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .completedWithErrors: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "minus.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .success: .green
        case .completedWithErrors: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}

struct StatusLabel: View {
    let status: RunStatus
    var body: some View {
        Label(status.label, systemImage: status.icon)
            .foregroundStyle(status.color)
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.section) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch model.section ?? .jobs {
            case .jobs: JobsView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .sheet(item: $model.deletionPrompt) { DeletionPreviewSheet(prompt: $0) }
        .alert(model.alert?.title ?? "",
               isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert?.message ?? "")
        }
    }
}

// MARK: - Jobs

struct JobsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            List(model.jobs, selection: $model.selectedJobID) { job in
                JobRow(job: job)
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)

            Group {
                if let id = model.selectedJobID, let binding = model.binding(for: id) {
                    JobDetailView(job: binding)
                } else {
                    ContentUnavailableView {
                        Label("No Backup Job Selected", systemImage: "externaldrive")
                    } description: {
                        Text("Create a job to choose what to back up and where.")
                    } actions: {
                        Button("New Backup Job") { model.addJob() }
                    }
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Backup Jobs")
        .toolbar {
            ToolbarItemGroup {
                Button { model.addJob() } label: { Label("New Job", systemImage: "plus") }
                    .help("Create a backup job")
                Button {
                    if let id = model.selectedJobID { model.deleteJob(id) }
                } label: { Label("Remove Job", systemImage: "minus") }
                    .help("Remove the selected job. Backed-up files are not touched.")
                    .disabled(model.selectedJobID.map { model.isRunning($0) } ?? true)
            }
        }
    }
}

struct JobRow: View {
    @EnvironmentObject var model: AppModel
    let job: BackupJob

    private func short(_ path: String) -> String {
        path.isEmpty ? "Not set" : (path as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.name.isEmpty ? "Untitled" : job.name).font(.headline)
            Text("\(short(job.sourcePath))  →  \(short(job.destinationPath))")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if model.isRunning(job.id) {
                Label("Running…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.blue)
            } else if let last = model.lastRun(for: job.id) {
                HStack(spacing: 4) {
                    StatusLabel(status: last.status)
                    Text("· \(Format.date(last.finishedAt))").foregroundStyle(.secondary)
                }
                .font(.caption).lineLimit(1)
            } else {
                Text("Never run").font(.caption).foregroundStyle(.secondary)
            }
            if let next = model.nextRun(for: job) {
                Text("Next: \(Format.date(next))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct JobDetailView: View {
    @EnvironmentObject var model: AppModel
    @Binding var job: BackupJob

    private var running: BackupProgress? { model.progress[job.id] }
    private var validation: ValidationResult? {
        job.sourcePath.isEmpty || job.destinationPath.isEmpty
            ? nil : PathValidator.validate(source: job.sourcePath, destination: job.destinationPath)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $job.name)
            }

            Section("What and Where") {
                PathRow(title: "Source", caption: "Copied from here. Never modified.", icon: "folder",
                        path: $job.sourcePath, chooseMessage: "Choose the folder or volume to back up.")
                PathRow(title: "Destination", caption: "Copied to here.", icon: "externaldrive",
                        path: $job.destinationPath, chooseMessage: "Choose where the backup is stored.")
                if let validation {
                    ForEach(validation.issues, id: \.self) { issue in
                        Label(issue.userMessage, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                    }
                    ForEach(validation.warnings, id: \.self) { warning in
                        Label(warning.userMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                }
            }
            .disabled(running != nil)

            Section("Mode") {
                Picker("Mode", selection: $job.mode) {
                    Text("Backup").tag(SyncMode.backup)
                    Text("Mirror").tag(SyncMode.mirror)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(job.mode == .backup
                     ? "Adds new and changed files to the destination. Nothing in the destination is ever deleted."
                     : "Makes the destination match the source. Before anything is deleted you are shown the list and asked to confirm. Scheduled runs never delete.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(running != nil)

            Section("Schedule") {
                Picker("Run", selection: $job.schedule.kind) {
                    Text("Manually").tag(Schedule.Kind.manual)
                    Text("Every day").tag(Schedule.Kind.daily)
                    Text("Every week").tag(Schedule.Kind.weekly)
                }
                if job.schedule.kind == .weekly {
                    Picker("Day", selection: $job.schedule.weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                if job.schedule.kind != .manual {
                    HStack {
                        Picker("Time", selection: $job.schedule.hour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .frame(maxWidth: 160)
                        Text(":")
                        Picker("Minute", selection: $job.schedule.minute) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 70)
                    }
                    Text("Schedules run while SwiftClone is open.").font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Also run when the destination drive is connected", isOn: $job.schedule.runWhenDestinationAppears)
            }

            Section("Verification") {
                Picker("After copying", selection: $job.verification) {
                    Text("Don't verify").tag(VerificationMode.none)
                    Text("Compare sizes and dates (fast)").tag(VerificationMode.metadata)
                    Text("Compare checksums (slow, thorough)").tag(VerificationMode.checksum)
                }
            }

            Section("Status") {
                if let running {
                    RunningView(jobID: job.id, progress: running)
                } else {
                    if let last = model.lastRun(for: job.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                StatusLabel(status: last.status)
                                Spacer()
                                Text(Format.date(last.finishedAt)).foregroundStyle(.secondary)
                            }
                            Text(last.summary).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("This job hasn't run yet.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Restore Files…") { model.restoreFiles(from: job) }
                            .disabled(job.destinationPath.isEmpty)
                        Spacer()
                        Button("Start Backup") { model.start(job) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("r")
                            .disabled(validation?.isValid != true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PathRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let caption: String
    let icon: String
    @Binding var path: String
    let chooseMessage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: icon).frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(path.isEmpty ? "Not set" : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") {
                if let chosen = model.chooseFolder(title: chooseMessage, startingAt: path) { path = chosen }
            }
        }
    }
}

struct RunningView: View {
    @EnvironmentObject var model: AppModel
    let jobID: UUID
    let progress: BackupProgress

    private var title: String {
        if model.paused.contains(jobID) { return "Paused" }
        switch progress.phase {
        case .preparing: return "Preparing…"
        case .scanning: return "Checking for changes… \(progress.filesDone.formatted()) files to copy so far"
        case .copying: return "Copying \(progress.filesDone.formatted()) of \(progress.filesTotal.formatted()) files"
        case .verifying: return "Verifying \(progress.filesDone.formatted()) of \(progress.filesTotal.formatted()) files"
        case .finished: return "Finishing…"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if progress.phase == .copying && progress.bytesTotal > 0 {
            parts.append("\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal))")
        }
        if let remaining = progress.estimatedSecondsRemaining() {
            parts.append("about \(Format.duration(remaining)) remaining")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(progress.currentPath.isEmpty ? " " : progress.currentPath)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Text(detail.isEmpty ? " " : detail).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.paused.contains(jobID) ? "Resume" : "Pause") { model.togglePause(jobID) }
                Button("Cancel") { model.cancel(jobID) }
            }
        }
    }
}

// MARK: - Deletion preview

struct DeletionPreviewSheet: View {
    @EnvironmentObject var model: AppModel
    let prompt: DeletionPrompt
    private static let displayLimit = 1000

    private var fileCount: Int { prompt.scan.deletions.reduce(0) { $0 + $1.fileCount } }
    private var bytes: Int64 { prompt.scan.deletions.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Mirroring would delete \(fileCount.formatted()) file\(fileCount == 1 ? "" : "s") from the destination",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold()).symbolRenderingMode(.multicolor)
            Text("These items are in **\(prompt.job.destinationPath)** but not in the source. Deleting them frees \(Format.bytes(bytes)) and cannot be undone. The source is not affected.")
                .fixedSize(horizontal: false, vertical: true)

            List(prompt.scan.deletions.prefix(Self.displayLimit)) { item in
                HStack {
                    Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(item.path).lineLimit(1).truncationMode(.middle)
                        if item.isDirectory {
                            Text("Folder and its \(item.fileCount.formatted()) file\(item.fileCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if item.replacedByDifferentType {
                            Text("Replaced by a \(item.isDirectory ? "file" : "folder") with the same name from the source")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(Format.bytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 220)
            if prompt.scan.deletions.count > Self.displayLimit {
                Text("Showing the first \(Self.displayLimit.formatted()) of \(prompt.scan.deletions.count.formatted()) items.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { model.deletionPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Back Up Without Deleting") { model.resolve(prompt, delete: false) }
                    .keyboardShortcut(.defaultAction)
                Button("Delete and Mirror", role: .destructive) { model.resolve(prompt, delete: true) }
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No Backups Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Each backup run is recorded here."))
            } else {
                List(model.history) { run in HistoryRow(run: run) }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button("Clear History") { model.clearHistory() }.disabled(model.history.isEmpty)
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let run: RunRecord

    private var verificationText: String {
        guard let v = run.verification else { return "Not verified" }
        let kind = v.mode == .checksum ? "checksums" : "sizes and dates"
        return v.passed ? "Verified \(v.filesChecked.formatted()) files (\(kind))"
                        : "\(v.mismatches.formatted()) of \(v.filesChecked.formatted()) files failed verification"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(run.jobName).font(.headline)
                StatusLabel(status: run.status).font(.callout)
                Spacer()
                if let log = run.logPath {
                    Button("Show Log") { model.reveal(log) }.buttonStyle(.link)
                }
            }
            Text("\(Format.date(run.startedAt)) – \(run.finishedAt.formatted(date: .omitted, time: .shortened)) · \(Format.duration(run.duration))")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                GridRow {
                    stat("Files copied", run.filesCopied.formatted())
                    stat("Data transferred", Format.bytes(run.bytesTransferred))
                    stat("Deleted", run.itemsDeleted.formatted())
                    stat("Errors", run.errorCount.formatted())
                }
            }
            Label(verificationText, systemImage: run.verification == nil ? "minus" : (run.verification!.passed ? "checkmark.seal" : "xmark.seal"))
                .font(.callout)
                .foregroundStyle(run.verification?.passed == false ? Color.red : Color.secondary)
            Text(run.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !run.errors.isEmpty {
                DisclosureGroup("Problems (\(run.errorCount.formatted()))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(run.errors) { error in
                            VStack(alignment: .leading) {
                                Text(error.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(error.message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if run.errorCount > run.errors.count {
                            Text("…and \((run.errorCount - run.errors.count).formatted()) more in the log.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.body.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Permissions") {
                Text("To back up protected folders such as Mail, Messages or other users' files, SwiftClone needs Full Disk Access.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Logs") {
                Toggle("Log every copied file", isOn: $model.verboseLogging)
                Text("Errors and deletions are always logged. Turn this on only when troubleshooting; large backups produce very large logs.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Show Logs in Finder") {
                    try? FileManager.default.createDirectory(at: model.logDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.logDirectory)
                }
            }
            Section("Data") {
                LabeledContent("Jobs and history", value: model.store.directory.path)
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: model.store.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.store.directory)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
