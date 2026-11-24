import Foundation
import Testing

@testable import LeverageApp

@MainActor
@Suite("Work reference input")
struct WorkReferenceInputTests {
    private struct Clipboard: WorkReferencePasteboard {
        let text: String?
        func readString() -> String? { text }
    }

    private struct FolderPicker: WorkReferenceFolderPicker {
        let path: String?
        func chooseFolder() -> String? { path }
    }

    @Test("both shortcuts are available without a project and with an empty work reference")
    func buttons() {
        let projectID = UUID()
        #expect(WorkReferenceInput.showsButtons(projectID: nil, reference: "~/work"))
        #expect(WorkReferenceInput.showsButtons(projectID: projectID, reference: " \n "))
        #expect(!WorkReferenceInput.showsButtons(projectID: projectID, reference: "~/work"))
    }

    @Test("Paste link trims and accepts supported remote links and local paths", arguments: [
        "https://example.invalid/reports?view=weekly",
        "http://example.invalid",
        "ssh://git@example.invalid/team/reports",
        "git://example.invalid/reports",
        "file:///tmp/Example%20Folder",
        "file:/tmp/reports",
        "git@example.invalid:team/reports",
        "/tmp/Example Folder",
        "~",
        "~/Example Folder",
        "/" + String(repeating: "a", count: 1_999),
    ])
    func pasteLink(reference: String) {
        var input = WorkReferenceInput(
            pasteboard: Clipboard(text: " \n\t\(reference) \n "), folderPicker: FolderPicker(path: nil))
        #expect(input.pasteLink() == reference)
        #expect(input.pasteProblem == nil)
    }

    @Test("Paste link refuses an empty clipboard or text that is not a single supported reference", arguments: [
        nil, "", "a note to the team", "https://", "https://example.invalid/one two",
        "ftp://example.invalid/reports", "reports/today", "git@example.invalid:", "file:reports",
        "/tmp/one\n/tmp/two", "/" + String(repeating: "a", count: 2_000),
    ] as [String?])
    func unsupportedPaste(text: String?) {
        var input = WorkReferenceInput(pasteboard: Clipboard(text: text), folderPicker: FolderPicker(path: nil))
        #expect(input.pasteLink() == nil)
        #expect(input.pasteProblem?.text == "The clipboard holds no link or folder path.")
        input.referenceChanged()
        #expect(input.pasteProblem == nil)
    }

    @Test("Paste link refuses addresses carrying sign-in details", arguments: [
        "https://sample:made-up@example.invalid/reports",
        "https://sample@example.invalid/reports",
        "ssh://git:made-up@example.invalid/reports",
        "git:made-up@example.invalid:reports",
        "file:///tmp/example?token=made-up",
        "git@example.invalid:reports?session=made-up",
    ] + ["ACCESS_TOKEN", "%73ecret", "password", "pwd", "api-key", "apikey",
         "key", "authorization", "signature", "sig", "credential", "session_id"].map {
        "https://example.invalid/reports?view=weekly&\($0)=made-up"
    })
    func secretPaste(text: String) {
        var input = WorkReferenceInput(pasteboard: Clipboard(text: text), folderPicker: FolderPicker(path: nil))
        #expect(input.pasteLink() == nil)
        #expect(input.pasteProblem?.text == "That link carries sign-in details. Paste one without them.")
    }

    @Test("Choose folder abbreviates paths under home, keeps other paths and returns no change on Cancel")
    func chooseFolder() {
        let homePath = (NSHomeDirectory() as NSString).appendingPathComponent("leverage-example")
        let homePicker = WorkReferenceInput(
            pasteboard: Clipboard(text: nil), folderPicker: FolderPicker(path: homePath))
        let isHomeRelative = homePicker.chooseFolder() == "~/leverage-example"
        #expect(isHomeRelative)

        let otherPicker = WorkReferenceInput(
            pasteboard: Clipboard(text: nil), folderPicker: FolderPicker(path: "/tmp/Example Folder"))
        #expect(otherPicker.chooseFolder() == "/tmp/Example Folder")

        var cancelled = WorkReferenceInput(pasteboard: Clipboard(text: nil), folderPicker: FolderPicker(path: nil))
        let reference = "~/work/reports"
        #expect((cancelled.pasteLink() ?? reference) == reference)
        #expect((cancelled.chooseFolder() ?? reference) == reference)
        #expect(cancelled.pasteProblem?.text == "The clipboard holds no link or folder path.")
    }
}

// Compile the acceptance tests before the form has work-reference shortcuts.
@MainActor
private protocol WorkReferencePasteboard {
    func readString() -> String?
}

@MainActor
private protocol WorkReferenceFolderPicker {
    func chooseFolder() -> String?
}

@MainActor
private struct WorkReferenceInput {
    var pasteProblem: AddTaskCopy? { nil }
    init(pasteboard: any WorkReferencePasteboard, folderPicker: any WorkReferenceFolderPicker) {}
    static func showsButtons(projectID: UUID?, reference: String) -> Bool { false }
    mutating func pasteLink() -> String? { nil }
    mutating func referenceChanged() {}
    func chooseFolder() -> String? { nil }
}
