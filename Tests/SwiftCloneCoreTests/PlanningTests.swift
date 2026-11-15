import Foundation
import Testing
@testable import SwiftCloneCore

private func file(_ name: String, size: Int64 = 10, mtime: Int64 = 1_000) -> FileEntry {
    FileEntry(name: name, kind: .file, size: size, mtime: mtime)
}
private func dir(_ name: String) -> FileEntry { FileEntry(name: name, kind: .directory) }
private func plan(_ s: [FileEntry], _ d: [FileEntry], _ mode: SyncMode = .backup,
                  tolerance: Int64 = 0, excluded: Set<String> = []) -> [PlanAction] {
    BackupPlanner.plan(source: s, destination: d, mode: mode, toleranceNanos: tolerance, excludedNames: excluded)
}

@Suite struct ChangeDetectionTests {
    @Test func identicalMetadataIsUnchanged() {
        #expect(ChangeDetector.isUnchanged(source: file("a"), destination: file("a"), toleranceNanos: 0))
    }

    @Test func sizeOrTimeOrKindDifferenceIsAChange() {
        #expect(!ChangeDetector.isUnchanged(source: file("a", size: 11), destination: file("a"), toleranceNanos: 0))
        #expect(!ChangeDetector.isUnchanged(source: file("a", mtime: 1_001), destination: file("a"), toleranceNanos: 0))
        #expect(!ChangeDetector.isUnchanged(source: file("a"), destination: dir("a"), toleranceNanos: 0))
    }

    @Test func olderSourceStillCountsAsChanged() {
        // A file restored from an older version must overwrite a newer backup copy.
        #expect(!ChangeDetector.isUnchanged(source: file("a", mtime: 500), destination: file("a", mtime: 1_000), toleranceNanos: 0))
    }

    @Test func toleranceAbsorbsTimestampRounding() {
        let src = file("a", mtime: 5_900_000_000), dst = file("a", mtime: 5_000_000_000)
        #expect(!ChangeDetector.isUnchanged(source: src, destination: dst, toleranceNanos: 0))
        #expect(ChangeDetector.isUnchanged(source: src, destination: dst, toleranceNanos: 1_000_000_000))
    }

    @Test func toleranceDependsOnFilesystem() {
        #expect(ChangeDetector.mtimeTolerance(forFilesystem: "apfs") == 0)
        #expect(ChangeDetector.mtimeTolerance(forFilesystem: "hfs") == 1_000_000_000)
        #expect(ChangeDetector.mtimeTolerance(forFilesystem: "exfat") == 2_000_000_000)
        #expect(ChangeDetector.mtimeTolerance(forFilesystem: "msdos") == 2_000_000_000)
    }
}

@Suite struct BackupPlanningTests {
    @Test func newItemsAreCopiedOrCreated() {
        #expect(plan([file("a"), dir("d")], []) == [.copy(file("a"), isNew: true), .createDirectory(dir("d"))])
    }

    @Test func unchangedIsSkippedAndChangedIsCopied() {
        let actions = plan([file("same"), file("grown", size: 20)], [file("same"), file("grown")])
        #expect(actions == [.skipUnchanged(file("same")), .copy(file("grown", size: 20), isNew: false)])
    }

    @Test func existingFolderIsDescended() {
        #expect(plan([dir("d")], [dir("d")]) == [.descend(dir("d"))])
    }

    @Test func excludedNamesAreIgnoredOnBothSides() {
        let actions = plan([file(".DS_Store"), file("a")], [file(".DS_Store"), file("a")], .mirror, excluded: [".DS_Store"])
        #expect(actions == [.skipUnchanged(file("a"))])
    }

    @Test func specialFilesAreSkipped() {
        let socket = FileEntry(name: "sock", kind: .other)
        #expect(plan([socket], []) == [.skipUnsupported(socket)])
    }

    @Test func typeMismatchIsAConflictNotACopy() {
        #expect(plan([file("x")], [dir("x")]) == [.typeConflict(source: file("x"), destination: dir("x"))])
        #expect(plan([dir("x")], [file("x")]) == [.typeConflict(source: dir("x"), destination: file("x"))])
    }

    @Test func partialTempFilesAreNeverMatchedOrDeleted() {
        let partial = file(".a.swiftclone-partial")
        #expect(plan([file("a")], [partial], .mirror) == [.copy(file("a"), isNew: true)])
    }

    @Test func composedAndDecomposedNamesMatch() {
        let composed = file("caf\u{00E9}.txt"), decomposed = file("cafe\u{0301}.txt")
        #expect(plan([composed], [decomposed], .mirror) == [.skipUnchanged(composed)])
    }
}

@Suite struct MirrorDeletionPlanningTests {
    @Test func backupModeNeverPlansADeletion() {
        let actions = plan([file("keep")], [file("keep"), file("extra"), dir("old")], .backup)
        #expect(actions == [.skipUnchanged(file("keep"))])
    }

    @Test func mirrorModePlansDeletionOfDestinationOnlyItems() {
        let actions = plan([file("keep")], [file("keep"), file("extra"), dir("old")], .mirror)
        #expect(actions == [.skipUnchanged(file("keep")), .delete(file("extra")), .delete(dir("old"))])
    }

    @Test func emptySourceInBackupModePlansNothing() {
        // The classic disaster: source unmounted/empty must not wipe a backup.
        #expect(plan([], [file("a"), file("b")], .backup).isEmpty)
    }
}
