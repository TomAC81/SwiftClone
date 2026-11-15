import Foundation

/// The job database: two JSON files in one directory. Small, human-readable,
/// and written atomically so a crash cannot corrupt it.
public struct Persistence: Sendable {
    public let directory: URL
    public static let historyLimit = 500

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftClone", isDirectory: true)
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SwiftClone", isDirectory: true)
    }

    private var jobsURL: URL { directory.appendingPathComponent("jobs.json") }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load<T: Decodable>(_ url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([T].self, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: [T], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    public func loadJobs() throws -> [BackupJob] { try load(jobsURL) }
    public func saveJobs(_ jobs: [BackupJob]) throws { try save(jobs, to: jobsURL) }

    /// Newest first.
    public func loadHistory() throws -> [RunRecord] { try load(historyURL) }

    public func saveHistory(_ runs: [RunRecord]) throws {
        try save(Array(runs.prefix(Self.historyLimit)), to: historyURL)
    }
}
