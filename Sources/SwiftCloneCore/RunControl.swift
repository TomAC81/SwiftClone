import Foundation

/// Pause and cancel switch shared between the UI and a running backup.
public final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public var isPaused: Bool { lock.withLock { paused } }

    /// Stops the run. A file being copied is abandoned mid-way; its partial
    /// temp file is removed and the previous destination file stays intact.
    public func cancel() {
        release { cancelled = true }
    }

    /// Takes effect before the next file starts; files already in flight finish.
    public func pause() {
        lock.withLock { if !cancelled { paused = true } }
    }

    public func resume() {
        release { paused = false }
    }

    private func release(_ change: () -> Void) {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            change()
            defer { waiters = [] }
            return waiters
        }
        toResume.forEach { $0.resume() }
    }

    /// Suspends while paused. Returns immediately otherwise.
    public func waitIfPaused() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let wait: Bool = lock.withLock {
                if paused && !cancelled { waiters.append(c); return true }
                return false
            }
            if !wait { c.resume() }
        }
    }
}
