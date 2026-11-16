import Foundation
import Testing
@testable import SwiftCloneCore

@Suite struct BackupEngineTests {
    @Test func firstRunCopiesEverythingAndSecondRunCopiesNothing() async throws {
        let s = try Sandbox()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try s.write("src/a.txt", "alpha", mtime: old)
        try s.write("src/sub/deep/b.txt", "bravo")
        try FileManager.default.createSymbolicLink(atPath: s.src + "/link", withDestinationPath: "a.txt")

        let first = await BackupEngine(job: s.job(verification: .metadata)).run()
        #expect(first.status == .success)
        #expect(first.filesCopied == 3)
        #expect(first.bytesTransferred >= 10)
        #expect(first.verification?.passed == true)
        #expect(s.read("dst/a.txt") == "alpha")
        #expect(s.read("dst/sub/deep/b.txt") == "bravo")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.dst + "/link") == "a.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: s.dst + "/a.txt")
        #expect(attrs[.modificationDate] as? Date == old)

        let second = await BackupEngine(job: s.job()).run()
        #expect(second.status == .success)
        #expect(second.filesCopied == 0)
        #expect(second.filesUnchanged == 3)
    }

    @Test func onlyChangedFilesAreRecopied() async throws {
        let s = try Sandbox()
        try s.write("src/a.txt", "one")
        try s.write("src/b.txt", "two")
        _ = await BackupEngine(job: s.job()).run()
        try s.write("src/b.txt", "two, edited")

        let run = await BackupEngine(job: s.job()).run()
        #expect(run.filesCopied == 1)
        #expect(s.read("dst/b.txt") == "two, edited")
    }

    @Test func scanReportsWorkWithoutWriting() async throws {
        let s = try Sandbox()
        try s.write("src/a.txt", "12345")
        try s.write("src/d/b.txt", "123")
        let scan = try await BackupEngine(job: s.job()).scan()
        #expect(scan.filesToCopy == 2)
        #expect(scan.bytesToCopy == 8)
        #expect(!s.exists("dst/a.txt"))
        #expect(!s.exists("dst/d"))
    }

    @Test func insufficientSpaceFailsBeforeCopying() async throws {
        let s = try Sandbox()
        try s.write("src/a.txt", "some data")
        var engine = BackupEngine(job: s.job())
        engine.freeSpace = { _ in 1024 }
        let run = await engine.run()
        #expect(run.status == .failed)
        #expect(run.summary.contains("Not enough space"))
        #expect(!s.exists("dst/a.txt"))
    }

    @Test func overlappingPathsAreRefused() async throws {
        let s = try Sandbox()
        try s.write("src/inside/x.txt")
        var job = s.job()
        job.destinationPath = s.src + "/inside"
        let run = await BackupEngine(job: job).run()
        #expect(run.status == .failed)
        #expect(run.filesCopied == 0)
    }

    @Test func missingDestinationIsNeverCreated() async throws {
        let s = try Sandbox()
        try s.write("src/a.txt")
        var job = s.job()
        job.destinationPath = s.root + "/Volumes/Unplugged"
        let run = await BackupEngine(job: job).run()
        #expect(run.status == .failed)
        #expect(!s.exists("Volumes"))
    }

    @Test func cancelledRunReportsCancelledAndLeavesNoPartials() async throws {
        let s = try Sandbox()
        for i in 0..<50 { try s.write("src/f\(i).txt", "x") }
        let control = RunControl()
        control.cancel()
        let run = await BackupEngine(job: s.job()).run(control: control)
        #expect(run.status == .cancelled)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: s.dst)
        #expect(leftovers.isEmpty)
    }

    @Test func leftoverPartialFromInterruptedRunIsCleanedUp() async throws {
        let s = try Sandbox()
        try s.write("src/a.txt", "complete")
        try s.write("dst/.a.txt.swiftclone-partial", "half-writ")
        let run = await BackupEngine(job: s.job(mode: .mirror)).run()
        #expect(run.status == .success)
        #expect(s.read("dst/a.txt") == "complete")
        #expect(!s.exists("dst/.a.txt.swiftclone-partial"))
        #expect(run.itemsDeleted == 0)
    }

    @Test func unreadableFileIsReportedAndOthersStillCopied() async throws {
        let s = try Sandbox()
        try s.write("src/ok.txt", "fine")
        try s.write("src/locked.txt", "secret")
        chmod(s.src + "/locked.txt", 0o000)
        let run = await BackupEngine(job: s.job()).run()
        #expect(run.status == .completedWithErrors)
        #expect(run.errorCount == 1)
        #expect(run.errors.first?.path == "locked.txt")
        #expect(s.read("dst/ok.txt") == "fine")
    }

    @Test func checksumVerificationCatchesSilentCorruption() async throws {
        let s = try Sandbox()
        let when = Date(timeIntervalSince1970: 1_650_000_000)
        try s.write("src/a.txt", "original", mtime: when)
        _ = await BackupEngine(job: s.job()).run()
        // Same size and date, different bytes: invisible to metadata checks.
        try s.write("dst/a.txt", "0riginal", mtime: when)

        let metadata = await BackupEngine(job: s.job(verification: .metadata)).run()
        #expect(metadata.verification?.passed == true)

        let checksum = await BackupEngine(job: s.job(verification: .checksum)).run()
        #expect(checksum.verification?.mismatches == 1)
        #expect(checksum.status == .completedWithErrors)
    }

    @Test func largeTreeIsCopiedCompletely() async throws {
        let s = try Sandbox()
        for d in 0..<40 { for f in 0..<50 { try s.write("src/d\(d)/n\(d % 4)/f\(f).txt", "\(d)-\(f)") } }
        let run = await BackupEngine(job: s.job(verification: .metadata)).run()
        #expect(run.status == .success)
        #expect(run.filesCopied == 2000)
        #expect(run.verification?.filesChecked == 2000)
        #expect(s.read("dst/d39/n3/f49.txt") == "39-49")
    }

    @Test func runWritesALog() async throws {
        let s = try Sandbox()
        try s.write("src/a.txt")
        let logs = URL(fileURLWithPath: s.root + "/logs")
        let run = await BackupEngine(job: s.job(), logDirectory: logs).run()
        let text = try String(contentsOfFile: try #require(run.logPath), encoding: .utf8)
        #expect(text.contains("started"))
        #expect(text.contains("Finished: success"))
    }
}

@Suite struct MirrorDeletionProtectionTests {
    private func populated() async throws -> Sandbox {
        let s = try Sandbox()
        try s.write("src/keep.txt", "keep")
        try s.write("dst/extra.txt", "extra")
        try s.write("dst/old/inner.txt", "inner")
        return s
    }

    @Test func backupModeLeavesDestinationOnlyFilesAlone() async throws {
        let s = try await populated()
        let run = await BackupEngine(job: s.job(mode: .backup)).run()
        #expect(run.status == .success)
        #expect(run.itemsDeleted == 0)
        #expect(run.deletionsNotApproved == 0)
        #expect(s.read("dst/extra.txt") == "extra")
        #expect(s.read("dst/old/inner.txt") == "inner")
    }

    @Test func mirrorWithoutApprovalDeletesNothing() async throws {
        let s = try await populated()
        let run = await BackupEngine(job: s.job(mode: .mirror)).run()
        #expect(run.itemsDeleted == 0)
        #expect(run.deletionsNotApproved == 2)
        #expect(run.summary.contains("left in place"))
        #expect(s.exists("dst/extra.txt"))
        #expect(s.exists("dst/old/inner.txt"))
        #expect(s.read("dst/keep.txt") == "keep")
    }

    @Test func previewListsExactlyWhatWouldBeDeleted() async throws {
        let s = try await populated()
        let scan = try await BackupEngine(job: s.job(mode: .mirror)).scan()
        #expect(scan.deletions.map(\.path).sorted() == ["extra.txt", "old"])
        let folder = try #require(scan.deletions.first { $0.path == "old" })
        #expect(folder.isDirectory)
        #expect(folder.fileCount == 1)
        #expect(s.exists("dst/extra.txt"))   // preview itself removes nothing
    }

    @Test func mirrorWithApprovalDeletesOnlyApprovedPaths() async throws {
        let s = try await populated()
        let engine = BackupEngine(job: s.job(mode: .mirror))
        let scan = try await engine.scan()
        // Something lands in the destination after the user saw the preview.
        try s.write("dst/arrived-later.txt", "new")

        let run = await engine.run(approval: DeletionApproval(approving: scan.deletions))
        #expect(run.itemsDeleted == 2)
        #expect(!s.exists("dst/extra.txt"))
        #expect(!s.exists("dst/old"))
        #expect(s.read("dst/arrived-later.txt") == "new")
        #expect(run.deletionsNotApproved == 1)
    }

    @Test func deletingAFolderDoesNotFollowSymlinksOutOfTheDestination() async throws {
        let s = try Sandbox()
        try s.write("src/keep.txt")
        try s.write("outside/important.txt", "must survive")
        try FileManager.default.createDirectory(atPath: s.dst + "/old", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: s.dst + "/old/link", withDestinationPath: s.root + "/outside")
        let run = await BackupEngine(job: s.job(mode: .mirror)).run(approval: DeletionApproval(paths: ["old"]))
        #expect(run.itemsDeleted == 1)
        #expect(!s.exists("dst/old"))
        #expect(s.read("outside/important.txt") == "must survive")
    }

    @Test func partialApprovalIsHonouredExactly() async throws {
        let s = try await populated()
        _ = await BackupEngine(job: s.job(mode: .mirror)).run(approval: DeletionApproval(paths: ["extra.txt"]))
        #expect(!s.exists("dst/extra.txt"))
        #expect(s.exists("dst/old/inner.txt"))
    }

    @Test func approvalIsIgnoredInBackupMode() async throws {
        let s = try await populated()
        _ = await BackupEngine(job: s.job(mode: .backup)).run(approval: DeletionApproval(paths: ["extra.txt", "old"]))
        #expect(s.exists("dst/extra.txt"))
        #expect(s.exists("dst/old/inner.txt"))
    }

    @Test func folderIsNotReplacedByFileWithoutApproval() async throws {
        let s = try Sandbox()
        try s.write("src/thing", "now a file")
        try s.write("dst/thing/precious.txt", "precious")
        let run = await BackupEngine(job: s.job(mode: .backup)).run()
        #expect(run.status == .completedWithErrors)
        #expect(s.read("dst/thing/precious.txt") == "precious")

        let mirror = BackupEngine(job: s.job(mode: .mirror))
        let scan = try await mirror.scan()
        #expect(scan.deletions.first?.replacedByDifferentType == true)
        let approved = await mirror.run(approval: DeletionApproval(approving: scan.deletions))
        #expect(approved.status == .success)
        #expect(s.read("dst/thing") == "now a file")
    }
}
