import AppKit

/// The system pasteboard, the one place the app writes to it.
enum Pasteboard {
    /// Puts `text` on the pasteboard in place of what was there.
    @MainActor
    static func copy(_ text: String, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Puts a secret, such as a landing prompt with its token, on the
    /// pasteboard: kept on this Mac (no Universal Clipboard) and marked
    /// concealed, so clipboard-history tools skip it.
    @MainActor
    static func copySecret(_ text: String, to board: NSPasteboard = .general) {
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setString("", forType: concealed)
    }

    /// The marker clipboard tools agree on (nspasteboard.org).
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}
