import Foundation

/// Copies items out of a backup. Backups are ordinary folders, so this is a
/// convenience, not a requirement: Finder can do the same.
public enum Restorer {
    /// Restores each item into `folder`. Never overwrites: if a name is
    /// taken, the restored copy gets " (restored)" (then " (restored 2)" …).
    /// - Returns: the paths that were created.
    public static func restore(items: [String], into folder: String) throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        for item in items {
            let name = (item as NSString).lastPathComponent
            let target = uniquePath(in: folder, name: name)
            try fm.copyItem(atPath: item, toPath: target)
            created.append(target)
        }
        return created
    }

    static func uniquePath(in folder: String, name: String) -> String {
        let fm = FileManager.default
        let first = (folder as NSString).appendingPathComponent(name)
        guard fm.fileExists(atPath: first) else { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let suffix = n == 1 ? " (restored)" : " (restored \(n))"
            let candidate = (folder as NSString).appendingPathComponent(base + suffix + (ext.isEmpty ? "" : "." + ext))
            if !fm.fileExists(atPath: candidate) { return candidate }
            n += 1
        }
    }
}
