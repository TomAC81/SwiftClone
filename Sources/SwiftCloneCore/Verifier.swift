import Foundation
import CryptoKit

public enum Verifier {
    /// Walks the source and checks every file and symlink against the
    /// destination. Reports problems through `onMismatch`; never modifies anything.
    public static func verify(source: String, destination: String, mode: VerificationMode,
                              excluded: Set<String>, tolerance: Int64, control: RunControl,
                              onFile: (String) -> Void,
                              onMismatch: (String, String) -> Void) async throws -> VerificationSummary {
        var summary = VerificationSummary(mode: mode, filesChecked: 0, mismatches: 0)
        var pending = [""]
        var root = stat()
        let sourceDevice: dev_t? = stat(source, &root) == 0 ? root.st_dev : nil
        // Explicit stack instead of recursion: depth-independent memory.
        while let rel = pending.popLast() {
            await control.waitIfPaused()
            if control.isCancelled { throw CancellationError() }
            let srcDir = rel.isEmpty ? source : source + "/" + rel
            // Mirror the engine: folders on another volume were not backed up.
            var st = stat()
            if !rel.isEmpty, stat(srcDir, &st) == 0, let sourceDevice, st.st_dev != sourceDevice { continue }
            guard let entries = try? DirectoryReader.list(srcDir) else { continue }
            for e in entries where !excluded.contains(e.name) && !BackupPlanner.isPartial(e.name) {
                let path = rel.isEmpty ? e.name : rel + "/" + e.name
                switch e.kind {
                case .directory: pending.append(path)
                case .other: continue
                case .file, .symlink:
                    if control.isCancelled { throw CancellationError() }
                    summary.filesChecked += 1
                    onFile(path)
                    if let problem = check(e, source: source + "/" + path, destination: destination + "/" + path,
                                           mode: mode, tolerance: tolerance) {
                        summary.mismatches += 1
                        onMismatch(path, problem)
                    }
                }
            }
        }
        return summary
    }

    static func check(_ src: FileEntry, source: String, destination: String,
                      mode: VerificationMode, tolerance: Int64) -> String? {
        guard let dst = FileEntry.at(destination) else { return "Missing from the backup." }
        guard dst.kind == src.kind else { return "The backup has a different kind of item here." }
        guard dst.size == src.size else { return "Size differs from the source (it may have changed during the backup)." }
        if mode == .checksum && src.kind == .file {
            guard let a = sha256(source), let b = sha256(destination) else { return "Couldn't be read for checksum comparison." }
            return a == b ? nil : "Contents differ from the source (checksum mismatch)."
        }
        if abs(dst.mtime - src.mtime) > tolerance { return "Modification date differs from the source." }
        return nil
    }

    /// Streams the file in 1 MB chunks; never holds a whole file in memory.
    public static func sha256(_ path: String) -> SHA256.Digest? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer, size)
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
        }
        return hasher.finalize()
    }
}
