import AppKit
import Testing

@testable import LeverageApp

/// What the app puts on a pasteboard, on pasteboards of the test's own so
/// that the owner's clipboard is never touched.
@MainActor
@Suite("Pasteboard")
struct PasteboardTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @Test("a landing prompt is copied marked as a secret, so clipboard-history tools skip it")
    func secretIsMarked() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("something older", forType: .string)
        let text = "Join Leverage with \(AgentFixtures.madeUpToken)"
        Pasteboard.copySecret(text, to: board)
        #expect(board.string(forType: .string) == text)
        #expect(board.types?.contains(Self.concealed) == true)
    }

    @Test("a gallery prompt is copied as plain text, with no secret mark")
    func plainIsNotMarked() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        Pasteboard.copy("Build a made-up birthday page", to: board)
        #expect(board.string(forType: .string) == "Build a made-up birthday page")
        #expect(board.types?.contains(Self.concealed) != true)
    }
}
