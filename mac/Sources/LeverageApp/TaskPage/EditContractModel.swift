import Foundation
import LeverageKit
import Observation

/// The contract editor of a task that already has a contract: the same form as
/// Add task, filled in (HM-49). Save sends Edit contract; Save and send to
/// agents sends it and then Complete contract.
@MainActor
@Observable
final class EditContractModel {
    enum State: Equatable, Sendable {
        case editing
        case saving
        case saved
        case failed(ShellCopy)
    }

    private(set) var state: State = .editing
    var draft = ContractDraft()

    init(page: TaskPage, api: any OwnerAPI, onSaved: @escaping @MainActor () -> Void) {}

    var warning: AddTaskCopy? { nil }
    var canSave: Bool { false }
    var failure: ShellCopy? { nil }
    var isBusy: Bool { false }
    var savedWithoutSending: Bool { false }

    func save() async {}
    func saveAndSend() async {}
}
