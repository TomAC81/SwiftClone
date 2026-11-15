import Foundation
@testable import SwiftCloneCore

/// A scratch directory with `src` and `dst` folders, removed when released.
final class Sandbox {
    let root: String
    var src: String { root + "/src" }
    var dst: String { root + "/dst" }

    init() throws {
        root = NSTemporaryDirectory() + "swiftclone-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions that tests removed, so cleanup can succeed.
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let p as String in e { chmod(root + "/" + p, 0o700) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ path: String, _ text: String = "data", mtime: Date? = nil) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: full))
        if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: full) }
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool { FileEntry.at(root + "/" + path) != nil }

    func job(mode: SyncMode = .backup, verification: VerificationMode = .none) -> BackupJob {
        BackupJob(name: "Test", sourcePath: src, destinationPath: dst, mode: mode, verification: verification)
    }
}
