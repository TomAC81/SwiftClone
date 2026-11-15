import Foundation

public enum ChangeDetector {
    /// A destination item is up to date when its type, size and modification
    /// time match the source. Content is not read; that is what makes
    /// incremental runs fast. Checksum verification covers the paranoid case.
    public static func isUnchanged(source: FileEntry, destination: FileEntry, toleranceNanos: Int64) -> Bool {
        source.kind == destination.kind
            && source.size == destination.size
            && abs(source.mtime - destination.mtime) <= toleranceNanos
    }

    /// Filesystems store timestamps at different resolutions. Comparing an
    /// APFS nanosecond time with its rounded copy on HFS+ or exFAT must not
    /// make every file look changed on every run.
    public static func mtimeTolerance(forFilesystem type: String) -> Int64 {
        switch type.lowercased() {
        case "apfs": 0
        case "hfs": 1_000_000_000              // 1 s resolution
        default: 2_000_000_000                 // FAT is 2 s; be equally lenient with exFAT, SMB, NFS
        }
    }
}
