import Foundation
import LeverageKit
import Observation

/// The sheet behind "Let it through once": why the owner lets a check through,
/// and what that sends (RD-28, RD-48).
@MainActor
@Observable
final class LetThroughModel {
    enum State: Equatable, Sendable {
        case editing
        case saving
        case saved
        case failed(ShellCopy)
    }

    private(set) var state: State = .editing
    var reason = ""
    let checkID: UUID
    let ruleName: String

    init(check: RuleCheckRow, page: TaskPage, api: any OwnerAPI, onDone: @escaping @MainActor () -> Void) {
        checkID = check.id
        ruleName = check.ruleName
    }

    var canSend: Bool { false }
    var failure: ShellCopy? { nil }

    func send() async {}
}
