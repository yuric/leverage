import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class ImaginariumTryModel {
    enum Destination: Equatable {
        case ready, ideas

        var initialState: TaskState { self == .ideas ? .ideas : .backlog }
    }

    enum State: Equatable {
        case editing, saving, checking
        case failed(String)
        case saved(TaskState, reason: String?)
    }

    private struct Submission {
        let destination: Destination
        let projectID: UUID
        let prompt: String
        let addKey = IdempotencyKey()
        let completeKey = IdempotencyKey()
    }

    let entry: ImaginariumCatalog.Entry
    let catalogVersion: Int
    private let api: any OwnerAPI
    private var submission: Submission?
    private var taskID: UUID?
    private var editedPrompt: String?

    var fills: [String: String] = [:]
    var isEditingPrompt = false
    private(set) var state: State = .editing

    init(entry: ImaginariumCatalog.Entry, catalogVersion: Int, api: any OwnerAPI) {
        self.entry = entry
        self.catalogVersion = catalogVersion
        self.api = api
    }

    var filledPrompt: String { entry.filledPrompt(fills) }
    var prompt: String {
        get { editedPrompt ?? filledPrompt }
        set { if newValue != prompt { editedPrompt = newValue } }
    }
    var isEdited: Bool { editedPrompt != nil }
    var canEdit: Bool { submission == nil }
    var savedProjectID: UUID? { submission?.projectID }
    var isChecking: Bool { state == .checking }

    var criteria: [CriterionInput] {
        entry.doneWhen.map { CriterionInput(text: $0, kind: .build) }
            + [CriterionInput(text: ImaginariumCopy.reviewCriterion.text, kind: .review)]
    }

    func undoEdits() {
        editedPrompt = nil
        isEditingPrompt = false
    }

    func submit(_ destination: Destination, projectID: UUID) async {
        guard submission == nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submission = Submission(destination: destination, projectID: projectID, prompt: prompt)
        await send()
    }

    func retry() async {
        guard case .failed = state else { return }
        await send()
    }

    private func send() async {
        guard let submission else { return }
        state = .saving
        do {
            if taskID == nil {
                let request = AddTaskRequest(
                    title: entry.title, details: submission.prompt,
                    criteria: submission.destination == .ideas ? criteria : nil,
                    projectID: submission.projectID, priority: .normal, state: submission.destination.initialState,
                    imaginarium: ImaginariumSource(entryID: entry.id, catalogVersion: catalogVersion))
                let outcome = try await api.addTask(request, key: submission.addKey)
                guard let created = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
                taskID = created.taskID
            }
            if submission.destination == .ideas {
                state = .saved(.ideas, reason: nil)
                return
            }
            guard let taskID else { throw LeverageClientError.invalidBody }
            let request = CompleteContractRequest(
                title: entry.title, details: submission.prompt, criteria: criteria, workReference: nil)
            let outcome = try await api.completeContract(taskID: taskID, request, key: submission.completeKey)
            try await update(outcome)
        } catch let error as TransportError where taskID == nil && error.code == .invalid {
            // A rejected Add task never started. The owner can edit and send a new body.
            self.submission = nil
            state = .failed(ShellCopy.sentence(for: error).text)
        } catch {
            state = .failed(ShellCopy.sentence(for: error).text)
        }
    }

    func checkStatus() async {
        guard state == .checking, let submission else { return }
        do {
            let outcome = try await api.command(key: submission.completeKey)
            try Task.checkCancellation()
            try await update(outcome)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(ShellCopy.sentence(for: error).text)
        }
    }

    func watchStatus() async {
        while state == .checking && !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await checkStatus()
        }
    }

    private func update(_ outcome: PlainOutcome) async throws {
        switch outcome.outcome {
        case .completed:
            guard let taskID else { throw LeverageClientError.invalidBody }
            let page = try await api.task(id: taskID)
            try Task.checkCancellation()
            if page.task.state == .backlog {
                let hold = page.holds.last { $0.reason == .contractIncomplete && $0.closedAt == nil }
                let reason = hold.map { failedCheckReason(on: page, heldBy: $0) }
                state = .saved(.backlog, reason: reason)
            } else {
                state = .saved(.ready, reason: nil)
            }
        case .pending:
            state = .checking
        case .refused:
            let refusal = outcome.refusal
            let explanation = ShellCopy.refusal(refusal?.code ?? .invalidState).text
            if refusal?.code == .blockedByRule {
                state = .saved(.backlog, reason: refusal?.reason ?? explanation)
            } else {
                state = .failed(explanation)
            }
        }
    }

    private func failedCheckReason(on page: TaskPage, heldBy hold: Hold) -> String {
        let failed = page.ruleChecks.last { check in
            check.hook == .taskBeforeReady && check.result == .failed && check.overriddenAt == nil
                && (hold.ruleID == nil || check.ruleID == hold.ruleID)
        }
        return failed?.reason ?? ShellCopy.refusalBlockedByRule.text
    }
}
