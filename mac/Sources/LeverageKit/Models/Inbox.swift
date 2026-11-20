import Foundation

/// `InboxPage`: `GET /v1/owner/inbox`. The open Needs you items; with
/// `after_seq`, only those whose `inbox.opened` has a higher `seq` (HM-29).
public struct InboxPage: Codable, Equatable, Sendable {
    public let items: [InboxItem]
    /// The `after_seq` to ask with next.
    public let nextAfterSeq: Int

    public init(items: [InboxItem], nextAfterSeq: Int) {
        self.items = items
        self.nextAfterSeq = nextAfterSeq
    }

    enum CodingKeys: String, CodingKey {
        case items
        case nextAfterSeq = "next_after_seq"
    }
}
