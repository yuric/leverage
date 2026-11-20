import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// The settings folder of an account (L584, CL-18): the helper creates it,
/// never adopts one, and deletes it after a failed add.
@Suite("Account folders")
struct AccountFoldersTests {
    @Test("a credential's folder is new, empty, private and inside the support folder")
    func createsInsideSupportFolder() throws {
        let rig = try HelperRig()
        let id = UUID()

        let made = try rig.folders.createFresh(for: id)

        #expect(made.path == rig.support.appendingPathComponent("accounts/\(id.contractString)").path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.path).isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: made.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(rig.folders.existing(for: id)?.path == made.path)
    }

    @Test("never adopts: a folder left at that place is emptied, so its sign-in is not used")
    func neverAdoptsALeftFolder() throws {
        let rig = try HelperRig()
        let id = UUID()
        let first = try rig.folders.createFresh(for: id)
        try rig.tools.signIn("claude", accountFolder: first)
        #expect(rig.tools.isSignedIn("claude", accountFolder: first))

        let second = try rig.folders.createFresh(for: id)

        #expect(second.path == first.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
        #expect(!rig.tools.isSignedIn("claude", accountFolder: second))
    }

    @Test("never adopts another program's folder: a link at that place is replaced, its target untouched")
    func neverFollowsALink() throws {
        let rig = try HelperRig()
        let id = UUID()
        let outside = try rig.folder.folder("someone-elses-account")
        try Data("theirs\n".utf8).write(to: outside.appendingPathComponent("settings.json"))
        let place = rig.folders.folder(for: id)
        try FileManager.default.createDirectory(
            at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: place, withDestinationURL: outside)

        let made = try rig.folders.createFresh(for: id)

        let kind = try FileManager.default.attributesOfItem(atPath: made.path)[.type] as? FileAttributeType
        #expect(kind == .typeDirectory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: made.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("settings.json").path))
    }

    @Test("removing deletes the folder and what the sign-in wrote; removing a missing one is no error")
    func removes() throws {
        let rig = try HelperRig()
        let id = UUID()
        let made = try rig.folders.createFresh(for: id)
        try rig.tools.signIn("codex", accountFolder: made)

        rig.folders.remove(for: id)
        rig.folders.remove(for: id)

        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(rig.folders.existing(for: id) == nil)
    }
}
