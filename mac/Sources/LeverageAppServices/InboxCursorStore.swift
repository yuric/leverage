import Foundation
import LeverageKit

/// `InboxCursorStoring` on one small file in the support folder, mode 0600:
/// the last `inbox.opened` `seq` announced (plan HM-29). No secret. WP13
/// writes the file handling. This first version keeps the number in memory.
public final class InboxCursorStore: InboxCursorStoring, @unchecked Sendable {
    private let memory = InMemoryInboxCursor()

    /// `folder` is the support folder the file will be kept in.
    public init(folder: URL) {}

    public func load() -> Int { memory.load() }
    public func save(_ seq: Int) throws { try memory.save(seq) }
}
