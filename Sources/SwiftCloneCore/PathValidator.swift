import Foundation

public enum ValidationIssue: Error, Sendable, Equatable {
    case sourceNotSet
    case destinationNotSet
    case sourceMissing
    case sourceNotFolder
    case sourceUnreadable
    case destinationMissing
    case destinationNotFolder
    case destinationNotWritable
    case samePath
    case destinationInsideSource
    case sourceInsideDestination

    public var userMessage: String {
        switch self {
        case .sourceNotSet: "Choose a source folder or volume."
        case .destinationNotSet: "Choose a destination folder or volume."
        case .sourceMissing: "The source can't be found. If it is on an external drive, connect the drive and try again."
        case .sourceNotFolder: "The source must be a folder or a volume, not a single file."
        case .sourceUnreadable: "SwiftClone isn't allowed to read the source. Grant Full Disk Access in System Settings › Privacy & Security."
        case .destinationMissing: "The destination can't be found. If it is on an external drive, connect the drive and try again."
        case .destinationNotFolder: "The destination must be a folder or a volume."
        case .destinationNotWritable: "The destination is read-only or SwiftClone isn't allowed to write to it."
        case .samePath: "The source and the destination are the same place."
        case .destinationInsideSource: "The destination is inside the source, so the backup would try to copy itself."
        case .sourceInsideDestination: "The source is inside the destination. Pick a destination folder that doesn't contain the source."
        }
    }
}

public enum ValidationWarning: Sendable, Equatable {
    /// Both paths are on one volume: fine for folder sync, no protection against drive failure.
    case sameVolume

    public var userMessage: String {
        "Source and destination are on the same drive. This won't protect you if that drive fails."
    }
}

public enum PathRelation: Sendable, Equatable {
    case same, firstContainsSecond, secondContainsFirst, disjoint
}

public struct ValidationResult: Sendable, Equatable {
    public var issues: [ValidationIssue] = []
    public var warnings: [ValidationWarning] = []
    public var isValid: Bool { issues.isEmpty }
}

public enum PathValidator {
    /// Pure comparison of two paths by their components. Case-insensitive by
    /// default because the default macOS filesystems are.
    public static func relation(_ first: String, _ second: String, caseInsensitive: Bool = true) -> PathRelation {
        func parts(_ p: String) -> [String] {
            let std = (p as NSString).standardizingPath
            return std.split(separator: "/").map { caseInsensitive ? $0.lowercased() : String($0) }
        }
        let a = parts(first), b = parts(second)
        let common = zip(a, b).prefix { $0 == $1 }.count
        if common == a.count && common == b.count { return .same }
        if common == a.count { return .firstContainsSecond }
        if common == b.count { return .secondContainsFirst }
        return .disjoint
    }

    /// Resolves symlinks so two spellings of one location compare equal.
    public static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    private static func identity(_ path: String) -> (dev_t, ino_t)? {
        var st = stat()
        return stat(path, &st) == 0 ? (st.st_dev, st.st_ino) : nil
    }

    /// True when `ancestor` is `path` or one of its parents, judged by
    /// device+inode. This catches overlaps that string comparison misses
    /// (symlinked parents, case or Unicode-normalisation differences).
    public static func isSameOrAncestor(_ ancestor: String, of path: String) -> Bool {
        guard let target = identity(ancestor) else { return false }
        var current = resolved(path)
        while true {
            if let id = identity(current), id == target { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    public static func validate(source: String, destination: String) -> ValidationResult {
        var result = ValidationResult()
        if source.isEmpty { result.issues.append(.sourceNotSet) }
        if destination.isEmpty { result.issues.append(.destinationNotSet) }
        guard result.isValid else { return result }

        var isDir: ObjCBool = false
        let fm = FileManager.default
        if !fm.fileExists(atPath: source, isDirectory: &isDir) { result.issues.append(.sourceMissing) }
        else if !isDir.boolValue { result.issues.append(.sourceNotFolder) }
        else if access(source, R_OK | X_OK) != 0 { result.issues.append(.sourceUnreadable) }

        if !fm.fileExists(atPath: destination, isDirectory: &isDir) { result.issues.append(.destinationMissing) }
        else if !isDir.boolValue { result.issues.append(.destinationNotFolder) }
        else if access(destination, W_OK) != 0 || VolumeInfo(path: destination)?.isReadOnly == true {
            result.issues.append(.destinationNotWritable)
        }

        let src = resolved(source), dst = resolved(destination)
        var rel = relation(src, dst)
        if rel == .disjoint {
            if isSameOrAncestor(src, of: dst) { rel = .firstContainsSecond }
            else if isSameOrAncestor(dst, of: src) { rel = .secondContainsFirst }
        }
        switch rel {
        case .same: result.issues.append(.samePath)
        case .firstContainsSecond: result.issues.append(.destinationInsideSource)
        case .secondContainsFirst: result.issues.append(.sourceInsideDestination)
        case .disjoint: break
        }

        if result.isValid, let a = VolumeInfo(path: src), let b = VolumeInfo(path: dst), a.mountPoint == b.mountPoint {
            result.warnings.append(.sameVolume)
        }
        return result
    }
}
