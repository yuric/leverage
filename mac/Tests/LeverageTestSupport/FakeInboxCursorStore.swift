import Foundation
import LeverageKit

/// An `InboxCursorStoring` in memory, for tests. A test can start it at a
/// number, make saving fail, and read what was saved, in order.
public final class FakeInboxCursorStore: InboxCursorStoring, @unchecked Sendable {
    public let stored = Locked(0)
    /// Every number `save` was given, in order, failures included.
    public let saves = Locked<[Int]>([])
    /// When set, `save` throws it and keeps nothing.
    public let failure = Locked<(any Error)?>(nil)

    public init(stored: Int = 0) {
        self.stored.value = stored
    }

    public func load() -> Int { stored.value }

    public func save(_ seq: Int) throws {
        saves.update { $0.append(seq) }
        if let error = failure.value { throw error }
        stored.value = seq
    }
}
