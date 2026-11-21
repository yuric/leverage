import Foundation
import LeverageKit
import Observation

/// Edits the three settings independently. A retry keeps the key for an
/// unanswered command and skips changes the server already accepted.
@MainActor
@Observable
final class TaskSettingsModel {
    private enum Field: Hashable {
        case priority, project, cap
    }

    private enum Change: Equatable {
        case priority(Priority)
        case project(UUID?)
        case cap(Decimal?)

        var field: Field {
            switch self {
            case .priority: .priority
            case .project: .project
            case .cap: .cap
            }
        }
    }

    var priority: Priority
    var projectID: UUID?
    var capText: String
    private(set) var isSaving = false
    private(set) var failure: ShellCopy?

    private let taskID: UUID
    private let api: any OwnerAPI
    private let didChange: @MainActor () -> Void
    private var saved: [Field: Change]
    private var retries: [Field: (change: Change, key: IdempotencyKey)] = [:]

    init(task: TaskSummary, api: any OwnerAPI, didChange: @escaping @MainActor () -> Void) {
        taskID = task.id
        self.api = api
        self.didChange = didChange
        priority = task.priority
        projectID = task.projectID
        capText = Self.amountText(task.budgetCap)
        saved = [.priority: .priority(task.priority), .project: .project(task.projectID), .cap: .cap(task.budgetCap)]
    }

    private var trimmedCap: String { capText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var amount: Decimal? {
        let text = trimmedCap
        // Preserve an existing cap with sub-cent precision when its displayed
        // value is untouched.
        if case .cap(let savedAmount)? = saved[.cap], text == Self.amountText(savedAmount) {
            return savedAmount
        }
        guard text.wholeMatch(of: /[0-9]+(?:\.[0-9]{1,2})?/) != nil,
              let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              amount < 100_000_000
        else { return nil }
        return amount
    }

    var invalidCap: Bool { !trimmedCap.isEmpty && amount == nil }

    private var changes: [Change] {
        let edited: [Change] = [.priority(priority), .project(projectID), .cap(amount)]
        return edited.filter { saved[$0.field] != $0 || retries[$0.field] != nil }
    }

    var canSave: Bool { !isSaving && !invalidCap && !changes.isEmpty }

    func save() async -> Bool {
        guard canSave else { return false }
        let changes = changes
        isSaving = true
        failure = nil
        var changed = false
        defer {
            isSaving = false
            if changed { didChange() }
        }
        for change in changes {
            let pending = retries[change.field]
            let key = pending.flatMap { $0.change == change ? $0.key : nil } ?? IdempotencyKey()
            do {
                try await apply(change, key: key)
                changed = true
                saved[change.field] = change
                retries[change.field] = nil
            } catch {
                if IdempotencyKey.isKept(after: error) {
                    retries[change.field] = (change, key)
                } else if pending?.change == change {
                    retries[change.field] = nil
                }
                failure = ShellCopy.sentence(for: error)
                return false
            }
        }
        return true
    }

    private func apply(_ change: Change, key: IdempotencyKey) async throws {
        switch change {
        case .priority(let priority):
            _ = try await api.changeTaskPriority(
                taskID: taskID, ChangeTaskPriorityRequest(priority: priority), key: key
            ).completedResult()
        case .project(let id):
            _ = try await api.changeTaskProject(
                taskID: taskID, ChangeTaskProjectRequest(projectID: id), key: key
            ).completedResult()
        case .cap(let amount):
            _ = try await api.changeTaskCap(
                taskID: taskID, ChangeTaskCapRequest(budgetCap: amount), key: key
            ).completedResult()
        }
    }

    private static func amountText(_ amount: Decimal?) -> String {
        amount?.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(2))
        ) ?? ""
    }
}
