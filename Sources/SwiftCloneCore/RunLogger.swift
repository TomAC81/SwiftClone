import Foundation

/// Plain-text log, one file per run: `<time> <LEVEL> <message>`.
public final class RunLogger: @unchecked Sendable {
    public enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR", delete = "DELETE" }

    public let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()
    private let verbose: Bool
    private let formatter = ISO8601DateFormatter()

    public init?(directory: URL, jobName: String, date: Date, verbose: Bool) {
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let safeName = jobName.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        url = directory.appendingPathComponent("\(String(safeName))-\(stamp).log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        } catch { return nil }
        self.verbose = verbose
    }

    public func log(_ level: Level, _ message: String) {
        lock.withLock {
            let line = "\(formatter.string(from: Date())) \(level.rawValue) \(message)\n"
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Per-file detail; skipped unless verbose logging is on, since a large
    /// backup would otherwise write millions of lines.
    public func detail(_ message: @autoclosure () -> String) {
        if verbose { log(.info, message()) }
    }

    public func close() { lock.withLock { try? handle?.close() } }
}
