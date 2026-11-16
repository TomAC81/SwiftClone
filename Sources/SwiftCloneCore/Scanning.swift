import Foundation

public struct PosixError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32
    public let operation: String
    public let path: String

    public init(code: Int32 = errno, operation: String, path: String) {
        self.code = code; self.operation = operation; self.path = path
    }

    public var description: String { "\(operation): \(userMessage)" }

    /// errno translated for people who don't read errno.
    public var userMessage: String {
        switch code {
        case EACCES, EPERM: "Permission denied. SwiftClone may need Full Disk Access, or the file is locked."
        case ENOSPC, EDQUOT: "The destination is full."
        case ENOENT: "The file disappeared while it was being backed up."
        case EROFS: "The destination is read-only."
        case EIO, ENXIO, ENODEV: "The drive reported a read/write error or was disconnected."
        case ENAMETOOLONG: "The file name or path is too long for the destination."
        case EINVAL: "The destination's format can't store this file (name or type not supported)."
        case EFBIG: "The file is too large for the destination's format."
        case EXDEV: "It contains a separately mounted volume, which SwiftClone will not delete."
        default: String(cString: strerror(code))
        }
    }
}

public enum EntryKind: Sendable, Equatable { case file, directory, symlink, other }

/// One directory entry. Deliberately small: millions of these get created.
public struct FileEntry: Sendable, Equatable {
    public var name: String
    public var kind: EntryKind
    public var size: Int64
    /// Modification time in nanoseconds since 1970.
    public var mtime: Int64

    public init(name: String, kind: EntryKind, size: Int64 = 0, mtime: Int64 = 0) {
        self.name = name; self.kind = kind; self.size = size; self.mtime = mtime
    }

    init(name: String, stat st: stat) {
        self.name = name
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        size = Int64(st.st_size)
        mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }

    /// lstat of a single path, nil if it doesn't exist.
    public static func at(_ path: String) -> FileEntry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileEntry(name: (path as NSString).lastPathComponent, stat: st)
    }
}

public enum DirectoryReader {
    /// Lists one directory without following symlinks.
    /// opendir + fstatat costs one syscall per entry and allocates only the
    /// name string, which matters for trees with millions of small files.
    public static func list(_ path: String) throws -> [FileEntry] {
        guard let dir = opendir(path) else { throw PosixError(operation: "Opening folder", path: path) }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var entries: [FileEntry] = []
        while true {
            errno = 0
            guard let ent = readdir(dir) else {
                if errno != 0 { throw PosixError(operation: "Reading folder", path: path) }
                break
            }
            let name = withUnsafeBytes(of: &ent.pointee.d_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            // An entry can vanish between readdir and stat; that is not an error.
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            entries.append(FileEntry(name: name, stat: st))
        }
        return entries
    }

    /// Recursive file count and byte total, for the deletion preview.
    public static func treeStats(_ path: String) -> (files: Int, bytes: Int64) {
        var root = stat()
        guard lstat(path, &root) == 0, let entries = try? list(path) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for e in entries {
            if e.kind == .directory {
                var st = stat()
                // Don't count into a volume mounted below this folder.
                guard lstat(path + "/" + e.name, &st) == 0, st.st_dev == root.st_dev else { continue }
                let sub = treeStats(path + "/" + e.name)
                files += sub.files; bytes += sub.bytes
            } else {
                files += 1; bytes += e.size
            }
        }
        return (files, bytes)
    }
}
