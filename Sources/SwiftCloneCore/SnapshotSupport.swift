import Foundation

/// Snapshot layer, kept apart from file synchronisation.
///
/// Today this only answers "could a snapshot be used here?". Creating one
/// (fs_snapshot_create) needs root or the restricted
/// com.apple.developer.vfs.snapshot entitlement, so the engine never assumes
/// a snapshot exists and always works on the live filesystem.
public enum SnapshotSupport {
    public enum Capability: Sendable, Equatable {
        /// APFS volume: snapshots exist in principle, but SwiftClone lacks the privilege to make one.
        case needsPrivilege
        case unsupportedFilesystem(String)
        case unknown
    }

    public static func capability(forPath path: String) -> Capability {
        guard let info = VolumeInfo(path: path) else { return .unknown }
        return info.filesystemType.lowercased() == "apfs" ? .needsPrivilege : .unsupportedFilesystem(info.filesystemType)
    }
}
