import Foundation

/// Copies a single file or symlink so that the destination name only ever
/// holds a complete file.
public enum FileCopier {
    // copyfile(3) flag values. The compound macros (COPYFILE_ALL etc.) are
    // not imported into Swift, so the bits are spelled out here.
    private static let flagACL: UInt32 = 1 << 0
    private static let flagStat: UInt32 = 1 << 1
    private static let flagXattr: UInt32 = 1 << 2
    private static let flagData: UInt32 = 1 << 3
    private static let flagNoFollowSrc: UInt32 = 1 << 18
    private static let flagClone: UInt32 = 1 << 24
    static let flagsMetadata = flagACL | flagStat | flagXattr
    /// Data + metadata. CLONE asks APFS for an instant copy-on-write clone
    /// when both paths are on one volume and silently falls back to a real
    /// copy otherwise.
    static let flagsAll = flagsMetadata | flagData | flagClone | flagNoFollowSrc

    private final class Context {
        let shouldContinue: () -> Bool
        let onBytes: (Int64) -> Void
        var reported: Int64 = 0
        init(shouldContinue: @escaping () -> Bool, onBytes: @escaping (Int64) -> Void) {
            self.shouldContinue = shouldContinue; self.onBytes = onBytes
        }
    }

    public static func partialPath(for destination: String) -> String {
        let ns = destination as NSString
        return ns.deletingLastPathComponent + "/." + ns.lastPathComponent + BackupPlanner.partialSuffix
    }

    /// - Parameters:
    ///   - shouldContinue: polled during the copy; returning false aborts mid-file.
    ///   - onBytes: called with the number of newly written bytes.
    /// - Throws: `CancellationError` if aborted, `PosixError` on failure.
    public static func copy(from source: String, to destination: String, entry: FileEntry,
                            shouldContinue: @escaping () -> Bool = { true },
                            onBytes: @escaping (Int64) -> Void = { _ in }) throws {
        let temp = partialPath(for: destination)
        unlink(temp)   // stale partial from an interrupted run

        if entry.kind == .symlink {
            try copySymlink(from: source, to: temp)
        } else {
            let context = Context(shouldContinue: shouldContinue, onBytes: onBytes)
            let state = copyfile_state_alloc()
            defer { copyfile_state_free(state) }

            let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
                guard let ctx = ctx as UnsafeMutableRawPointer? else { return COPYFILE_CONTINUE }
                let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
                if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                    var copied: off_t = 0
                    copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                    if copied > c.reported {
                        c.onBytes(Int64(copied) - c.reported)
                        c.reported = Int64(copied)
                    }
                }
                return c.shouldContinue() ? COPYFILE_CONTINUE : COPYFILE_QUIT
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

            let rc = withExtendedLifetime(context) { copyfile(source, temp, state, copyfile_flags_t(flagsAll)) }
            if rc != 0 {
                let code = errno
                unlink(temp)
                if !shouldContinue() { throw CancellationError() }
                throw PosixError(code: code, operation: "Copying", path: source)
            }
            // Clones and tiny files finish without progress callbacks.
            if context.reported < entry.size { onBytes(entry.size - context.reported) }
        }

        // rename(2) is atomic within a volume: readers see the old file or
        // the new one, never a mixture.
        if rename(temp, destination) != 0 {
            let code = errno
            unlink(temp)
            throw PosixError(code: code, operation: "Replacing", path: destination)
        }
    }

    private static func copySymlink(from source: String, to temp: String) throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(source, &buffer, Int(PATH_MAX))
        guard length >= 0 else { throw PosixError(operation: "Reading link", path: source) }
        buffer[length] = 0
        guard symlink(buffer, temp) == 0 else { throw PosixError(operation: "Creating link", path: temp) }
        // Carry the link's own mtime over so it isn't seen as changed next run.
        var st = stat()
        if lstat(source, &st) == 0 {
            var times = [st.st_atimespec, st.st_mtimespec]
            utimensat(AT_FDCWD, temp, &times, AT_SYMLINK_NOFOLLOW)
        }
    }

    /// Copies permissions, times, flags, xattrs and ACLs onto an existing
    /// directory. Done after the directory's children are written, because
    /// writing children changes the directory's modification time.
    public static func copyDirectoryMetadata(from source: String, to destination: String) {
        copyfile(source, destination, nil, copyfile_flags_t(flagsMetadata))
    }
}
