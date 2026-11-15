import Foundation

/// Picks how many files to copy at once by watching throughput.
///
/// SSDs get faster with parallel small-file copies; spinning disks and cheap
/// USB bridges get slower because of seeking. Rather than guessing the
/// hardware, this climbs while throughput improves and backs off when it drops.
public struct AdaptiveConcurrency: Sendable, Equatable {
    public private(set) var limit: Int
    public let minimum: Int
    public let maximum: Int
    private var lastScore: Double?
    private var direction = 1

    public init(initial: Int = 2, minimum: Int = 1, maximum: Int = 8) {
        self.minimum = minimum
        self.maximum = max(minimum, maximum)
        self.limit = min(max(initial, minimum), self.maximum)
    }

    /// Feed one measurement window.
    public mutating func record(bytes: Int64, files: Int, seconds: Double) {
        guard seconds > 0, files > 0 || bytes > 0 else { return }
        // Small files are dominated by per-file overhead, so count each file
        // as if it were 64 KB of work in addition to its bytes.
        let score = (Double(bytes) + Double(files) * 65_536) / seconds
        defer { lastScore = score }
        guard let last = lastScore else { step(); return }
        if score < last * 0.95 { direction = -direction }      // got worse: turn around
        else if score < last * 1.05 { return }                 // flat: stay put
        step()
    }

    private mutating func step() {
        limit = min(max(limit + direction, minimum), maximum)
    }
}
