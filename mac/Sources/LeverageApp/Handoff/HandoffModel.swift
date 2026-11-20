import Foundation
import LeverageKit
import Observation

/// One account on the Handoff tab (HM-34 to HM-36).
struct HandoffRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let number: Int
    let name: String
    let state: String
    let tone: Tokens.Tone
    let handsOff: String
}

/// The Handoff tab's rows. Empty until WP16's code commit fills it in.
@MainActor
@Observable
final class HandoffModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var rows: [HandoffRow] = []

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void, now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current, locale: Locale = .current
    ) {}

    func load() async {}
    func attach(to feed: EventFeed) {}
    func detach() {}
}
