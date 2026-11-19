import AppKit

/// The system pasteboard, the one place the app writes to it.
enum Pasteboard {
    /// Puts `text` on the pasteboard in place of what was there.
    @MainActor
    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
