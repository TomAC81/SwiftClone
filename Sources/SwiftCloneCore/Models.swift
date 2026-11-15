import Foundation

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    /// Add and update files. Never removes anything from the destination.
    case backup
    /// Make the destination match the source. Removal needs explicit approval.
    case mirror
}

public enum VerificationMode: String, Codable, Sendable, CaseIterable {
    case none, metadata, checksum
}

public struct Schedule: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case manual, daily, weekly }
    public var kind: Kind
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar convention).
    public var weekday: Int
    public var runWhenDestinationAppears: Bool

    public init(kind: Kind = .manual, hour: Int = 2, minute: Int = 0, weekday: Int = 1,
                runWhenDestinationAppears: Bool = false) {
        self.kind = kind; self.hour = hour; self.minute = minute
        self.weekday = weekday; self.runWhenDestinationAppears = runWhenDestinationAppears
    }
}

public struct BackupJob: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var sourcePath: String
    public var destinationPath: String
    public var mode: SyncMode
    public var schedule: Schedule
    public var verification: VerificationMode
    /// File or folder names skipped wherever they occur (e.g. ".DS_Store").
    public var excludedNames: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String = "New Backup", sourcePath: String = "",
                destinationPath: String = "", mode: SyncMode = .backup, schedule: Schedule = Schedule(),
                verification: VerificationMode = .metadata,
                excludedNames: [String] = [".DS_Store", ".Trashes", ".Spotlight-V100", ".fseventsd"],
                createdAt: Date = Date()) {
        self.id = id; self.name = name; self.sourcePath = sourcePath
        self.destinationPath = destinationPath; self.mode = mode; self.schedule = schedule
        self.verification = verification; self.excludedNames = excludedNames; self.createdAt = createdAt
    }
}

public enum RunStatus: String, Codable, Sendable {
    case success, completedWithErrors, failed, cancelled
}

public struct RunError: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var message: String
    public init(path: String, message: String) { self.id = UUID(); self.path = path; self.message = message }
}

public struct VerificationSummary: Codable, Sendable, Equatable {
    public var mode: VerificationMode
    public var filesChecked: Int
    public var mismatches: Int
    public var passed: Bool { mismatches == 0 }
}

public struct RunRecord: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var jobID: UUID
    public var jobName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var status: RunStatus
    /// One plain-language sentence describing the outcome.
    public var summary: String
    public var filesCopied: Int = 0
    public var bytesTransferred: Int64 = 0
    public var filesUnchanged: Int = 0
    public var itemsDeleted: Int = 0
    /// Mirror-mode items left in place because their removal was not approved.
    public var deletionsNotApproved: Int = 0
    public var errorCount: Int = 0
    /// First errors only; the log file has all of them.
    public var errors: [RunError] = []
    public var verification: VerificationSummary?
    public var logPath: String?

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}
