import Foundation

/// Facts about the volume a path lives on, from statfs(2).
public struct VolumeInfo: Sendable, Equatable {
    public let filesystemType: String
    public let mountPoint: String
    public let availableBytes: Int64
    public let isReadOnly: Bool

    public init?(path: String) {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        filesystemType = withUnsafeBytes(of: &fs.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        mountPoint = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        // f_bavail is what an unprivileged user can actually use.
        availableBytes = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        isReadOnly = (fs.f_flags & UInt32(MNT_RDONLY)) != 0
    }
}
