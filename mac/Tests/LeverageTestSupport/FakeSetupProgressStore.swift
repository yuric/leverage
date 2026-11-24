import Foundation
import LeverageKit

/// A `SetupProgressStoring` in memory, for tests. A test can start it at a
/// choice, make saving fail, and read what was saved, in order.
public final class FakeSetupProgressStore: SetupProgressStoring, @unchecked Sendable {
    public let stored: Locked<SetupChoice>
    /// Every choice `save` was given, in order, failures included.
    public let saves = Locked<[SetupChoice]>([])
    /// When set, `save` throws it and keeps nothing.
    public let failure = Locked<(any Error)?>(nil)

    public init(stored: SetupChoice = .notChosen) {
        self.stored = Locked(stored)
    }

    public func load() -> SetupChoice { stored.value }

    public func save(_ choice: SetupChoice) throws {
        saves.update { $0.append(choice) }
        if let error = failure.value { throw error }
        stored.value = choice
    }
}
