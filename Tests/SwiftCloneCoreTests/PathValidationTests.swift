import Foundation
import Testing
@testable import SwiftCloneCore

@Suite struct PathValidationTests {
    @Test func relationOfPaths() {
        #expect(PathValidator.relation("/a/b", "/a/b") == .same)
        #expect(PathValidator.relation("/a/b/", "/a/b") == .same)
        #expect(PathValidator.relation("/a", "/a/b/c") == .firstContainsSecond)
        #expect(PathValidator.relation("/a/b/c", "/a") == .secondContainsFirst)
        #expect(PathValidator.relation("/a/b", "/a/c") == .disjoint)
        #expect(PathValidator.relation("/", "/Users") == .firstContainsSecond)
    }

    @Test func siblingWithSharedPrefixIsNotContained() {
        #expect(PathValidator.relation("/data/foo", "/data/foobar") == .disjoint)
    }

    @Test func caseAndDotDotAreNormalised() {
        #expect(PathValidator.relation("/Users/Tom/Docs", "/users/tom/docs/sub") == .firstContainsSecond)
        #expect(PathValidator.relation("/Users/Tom/Docs", "/users/tom/docs", caseInsensitive: false) == .disjoint)
        #expect(PathValidator.relation("/a/b/../c", "/a/c") == .same)
    }

    @Test func rejectsSamePath() throws {
        let s = try Sandbox()
        #expect(PathValidator.validate(source: s.src, destination: s.src).issues == [.samePath])
    }

    @Test func rejectsDestinationInsideSource() throws {
        let s = try Sandbox()
        try s.write("src/backups/x.txt")
        #expect(PathValidator.validate(source: s.src, destination: s.src + "/backups").issues == [.destinationInsideSource])
    }

    @Test func rejectsSourceInsideDestination() throws {
        let s = try Sandbox()
        #expect(PathValidator.validate(source: s.src, destination: s.root).issues == [.sourceInsideDestination])
    }

    @Test func symlinkCannotHideAnOverlap() throws {
        let s = try Sandbox()
        try s.write("src/inner/x.txt")
        try FileManager.default.createSymbolicLink(atPath: s.root + "/alias", withDestinationPath: s.src + "/inner")
        #expect(PathValidator.validate(source: s.src, destination: s.root + "/alias").issues == [.destinationInsideSource])
    }

    @Test func rejectsMissingOrNonFolderPaths() throws {
        let s = try Sandbox()
        try s.write("file.txt")
        #expect(PathValidator.validate(source: s.src, destination: s.root + "/nope").issues == [.destinationMissing])
        #expect(PathValidator.validate(source: s.root + "/nope", destination: s.dst).issues == [.sourceMissing])
        #expect(PathValidator.validate(source: s.root + "/file.txt", destination: s.dst).issues == [.sourceNotFolder])
        #expect(PathValidator.validate(source: "", destination: "").issues == [.sourceNotSet, .destinationNotSet])
    }

    @Test func rejectsReadOnlyDestination() throws {
        let s = try Sandbox()
        chmod(s.dst, 0o500)
        #expect(PathValidator.validate(source: s.src, destination: s.dst).issues == [.destinationNotWritable])
    }

    @Test func acceptsSeparateFoldersAndWarnsAboutSameVolume() throws {
        let s = try Sandbox()
        let r = PathValidator.validate(source: s.src, destination: s.dst)
        #expect(r.isValid)
        #expect(r.warnings == [.sameVolume])
    }
}
