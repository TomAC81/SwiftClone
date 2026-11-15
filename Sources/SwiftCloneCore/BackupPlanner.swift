import Foundation

public enum PlanAction: Sendable, Equatable {
    /// Folder exists only in the source: create it, then visit it.
    case createDirectory(FileEntry)
    /// Folder exists on both sides: visit it.
    case descend(FileEntry)
    /// File or symlink is new or changed.
    case copy(FileEntry, isNew: Bool)
    case skipUnchanged(FileEntry)
    /// Sockets, devices, FIFOs: not backed up.
    case skipUnsupported(FileEntry)
    /// Destination has a different kind of item under this name (e.g. a
    /// folder where the source has a file). Resolving it means removing the
    /// destination item, so it is handled like a deletion.
    case typeConflict(source: FileEntry, destination: FileEntry)
    /// Destination-only item. Only ever produced in mirror mode.
    case delete(FileEntry)
}

public enum BackupPlanner {
    /// Suffix of the temporary files SwiftClone writes while copying.
    public static let partialSuffix = ".swiftclone-partial"

    public static func isPartial(_ name: String) -> Bool { name.hasSuffix(partialSuffix) }

    /// Diffs one directory. Pure: no filesystem access, so every safety rule
    /// here is unit-tested directly.
    ///
    /// Names are matched with Swift String equality, which treats composed
    /// and decomposed Unicode as equal — HFS+ stores names decomposed while
    /// APFS preserves what it was given.
    public static func plan(source: [FileEntry], destination: [FileEntry], mode: SyncMode,
                            toleranceNanos: Int64, excludedNames: Set<String> = []) -> [PlanAction] {
        var destByName: [String: FileEntry] = [:]
        destByName.reserveCapacity(destination.count)
        for d in destination where !isPartial(d.name) { destByName[d.name] = d }

        var actions: [PlanAction] = []
        actions.reserveCapacity(source.count)
        var seen = Set<String>()

        for s in source {
            if excludedNames.contains(s.name) || isPartial(s.name) { continue }
            seen.insert(s.name)
            if s.kind == .other { actions.append(.skipUnsupported(s)); continue }
            guard let d = destByName[s.name] else {
                actions.append(s.kind == .directory ? .createDirectory(s) : .copy(s, isNew: true))
                continue
            }
            if d.kind != s.kind {
                actions.append(.typeConflict(source: s, destination: d))
            } else if s.kind == .directory {
                actions.append(.descend(s))
            } else if ChangeDetector.isUnchanged(source: s, destination: d, toleranceNanos: toleranceNanos) {
                actions.append(.skipUnchanged(s))
            } else {
                actions.append(.copy(s, isNew: false))
            }
        }

        // Backup mode stops here: destination-only items are never touched.
        guard mode == .mirror else { return actions }
        for (name, d) in destByName.sorted(by: { $0.key < $1.key })
        where !seen.contains(name) && !excludedNames.contains(name) {
            actions.append(.delete(d))
        }
        return actions
    }
}
