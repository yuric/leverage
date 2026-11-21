import Foundation
import LeverageKit
import Observation

/// The sheet behind "Let it through once": why the owner lets a check through,
/// and what that sends (RD-28, RD-48).
///
/// Save sends Override check with the reason, and, for a failed "ready to
/// start" check on a task still in Backlog, then Complete contract again with
/// the contract the task has, as the owner: an override completes nothing by
/// itself (RD-48). Each command keeps its key until it works, so pressing the
/// button again sends the same command; a changed reason is a new body and gets
/// a new key, and so does a press after a refusal. If the override worked and Complete contract did not, the next
/// press sends only Complete contract.
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

    /// Why the owner lets the check through. The owner's own words: stored with who and when.
    var reason = "" {
        didSet {
            guard reason != oldValue, !overridden else { return }
            overrideKey = nil
        }
    }

    let checkID: UUID
    let ruleName: String
    /// Whether Complete contract follows the override: a failed "ready to
    /// start" check on a task in Backlog (RD-48).
    let sendsContractAfter: Bool

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let taskID: UUID
    @ObservationIgnored private let storedContract: CompleteContractRequest
    @ObservationIgnored private let onDone: @MainActor () -> Void
    @ObservationIgnored private var overrideKey: IdempotencyKey?
    @ObservationIgnored private var completeKey: IdempotencyKey?
    /// The override worked; only Complete contract may be left to send.
    @ObservationIgnored private var overridden = false

    init(check: RuleCheckRow, page: TaskPage, api: any OwnerAPI, onDone: @escaping @MainActor () -> Void) {
        checkID = check.id
        ruleName = check.ruleName
        taskID = page.task.id
        self.api = api
        self.onDone = onDone
        sendsContractAfter = check.hook == .taskBeforeReady && check.result == .failed && page.task.state == .backlog
        storedContract = Self.storedContract(of: page)
    }

    /// The task's contract as it is stored: every field sent again as it stands, so
    /// the stored result is reused and the task becomes Ready (RD-48).
    private static func storedContract(of page: TaskPage) -> CompleteContractRequest {
        let task = page.task
        return CompleteContractRequest(
            title: task.title, goal: task.goal, details: task.details,
            criteria: page.criteria.sorted { $0.position < $1.position }
                .map { CriterionInput(text: $0.text, kind: $0.kind) },
            actions: page.contractActions, minimumStrengthRank: task.minimumStrengthRank, budgetCap: task.budgetCap,
            workReference: task.workReference)
    }

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isBusy: Bool { state == .saving }

    /// Whether the button is on: there is a reason (once the override worked, none is needed) and nothing is being sent.
    var canSend: Bool { !isBusy && state != .saved && (overridden || !trimmedReason.isEmpty) }

    /// The failure line, if the last try did not work.
    var failure: ShellCopy? {
        if case .failed(let copy) = state { copy } else { nil }
    }

    func send() async {
        guard canSend else { return }
        state = .saving
        do {
            if !overridden {
                let key = overrideKey ?? IdempotencyKey()
                overrideKey = key
                _ = try await api.overrideCheck(
                    checkID: checkID, OverrideCheckRequest(reason: trimmedReason), key: key
                ).completedResult()
                overridden = true
            }
            if sendsContractAfter {
                let key = completeKey ?? IdempotencyKey()
                completeKey = key
                try await api.completeContract(taskID: taskID, storedContract, key: key).acceptedWhilePending()
            }
            state = .saved
            onDone()
        } catch {
            // A refusal was answered: the next press is a new command with a
            // new key (review finding 16); a request with no answer keeps its key.
            if !IdempotencyKey.isKept(after: error) {
                if overridden { completeKey = nil } else { overrideKey = nil }
            }
            state = .failed(ShellCopy.sentence(for: error))
        }
    }
}
