import Foundation
import LeverageKit
import Observation

/// One Needs you item as a row of the screen.
struct NeedsYouRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: NeedsYouItem
    let taskID: UUID?
    let credentialID: UUID?
    let heading: String
    let body: String
    let buttons: [NeedsYouButton]
}

/// The Needs you screen (HM-21, HM-24): the open items from `list_inbox`, a
/// row for each kind the app can open, and the commands of its buttons.
@MainActor
@Observable
final class NeedsYouModel {
    enum State: Equatable, Sendable {
        case loading
        case loaded
        case failed(ShellCopy)
        /// The sign-in ended. The shell returns the app to Sign in.
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var rows: [NeedsYouRow] = []
    /// The row whose Cancel task is waiting for the owner's answer.
    private(set) var confirmingCancel: UUID?

    init(
        api: any OwnerAPI, noteRead: @escaping @MainActor (Int) -> Void,
        openTask: @escaping @MainActor (UUID) -> Void, timing: FollowTiming = .normal
    ) {}

    func load() async {}
    func perform(_ action: NeedsYouButton.Action, on rowID: UUID) async {}
    func confirmCancel() async {}
    func dismissCancel() {}
    func isWaitingForSignIn(_ id: UUID) -> Bool { false }
    func isBusy(_ id: UUID) -> Bool { false }
    func failure(for id: UUID) -> String? { nil }
    func attach(to feed: EventFeed) {}
    func detach() {}
}
