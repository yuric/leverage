import Foundation
import LeverageKit
import Observation

/// The sheet that adds a custom rule or changes one (RD-4, RD-6, RD-21,
/// RD-22, RD-24). Save sends every field the request has: the ones the
/// owner did not touch go as the current version has them, the route
/// among them, whatever its value, because Save replaces the version.
@MainActor
@Observable
final class RuleEditorModel {
    enum Mode: Equatable, Sendable {
        case add
        case change(RuleRow)
    }

    enum State: Equatable, Sendable {
        case editing
        case sending
        case done
        case failed(ShellCopy)
    }

    /// One whole-number parameter of an app rule, as the owner types it.
    struct ParameterField: Identifiable, Equatable, Sendable {
        let key: String
        let label: String
        var text: String
        var id: String { key }
    }

    /// The four moments a custom rule may use now; "before anything goes
    /// out" arrives with outward actions (RD-21).
    static let offeredHooks: [RuleHook] = [.taskBeforeReady, .taskBeforeClaim, .taskBeforeSubmit, .taskBeforeDone]
    /// The two scopes offered now (RD-22).
    static let offeredScopes: [RuleScopeKind] = [.allTasks, .checkerDecides]

    let mode: Mode
    private(set) var state: State = .editing

    var name: String
    var instruction: String
    var hook: RuleHook
    var scopeKind: RuleScopeKind
    var onFail: RuleOnFail?
    var parameters: [ParameterField]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let onDone: @MainActor () -> Void
    @ObservationIgnored private var lastSave: (request: SaveRuleRequest, key: IdempotencyKey)?
    @ObservationIgnored private var lastAdd: (request: AddRuleRequest, key: IdempotencyKey)?
    @ObservationIgnored private var revertKey: IdempotencyKey?
    @ObservationIgnored private var removeKey: IdempotencyKey?

    init(mode: Mode, api: any OwnerAPI, onDone: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.api = api
        self.onDone = onDone
        switch mode {
        case .add:
            name = ""
            instruction = ""
            hook = Self.offeredHooks[0]
            scopeKind = .allTasks
            onFail = nil
            parameters = []
        case .change(let row):
            let version = row.version
            name = version.name
            instruction = version.instruction ?? ""
            hook = version.hook
            scopeKind = version.scope.kind
            onFail = version.onFail
            parameters = (version.parameters ?? [:]).sorted { $0.key < $1.key }.compactMap { key, value in
                guard case .number(let number) = value, number == number.rounded(), abs(number) < 1e9 else { return nil }
                return ParameterField(key: key, label: RulesCopy.parameterLabel(for: key), text: String(Int(number)))
            }
        }
    }

    // MARK: what the sheet shows

    private var original: RuleVersion? {
        if case .change(let row) = mode { row.version } else { nil }
    }

    var isAdding: Bool { original == nil }
    var canEditName: Bool { original.map { $0.origin == .custom } ?? true }
    var showsInstruction: Bool { original.map { $0.checker == .model } ?? true }
    var showsScope: Bool {
        original.map { $0.checker == .model && Self.offeredScopes.contains($0.scope.kind) } ?? true
    }
    var showsOnFail: Bool { original.map { $0.kind == .gate } ?? false }
    var showsHook: Bool { isAdding }
    /// Revert goes back to the shipped wording, so it is on a shipped rule only (RD-5).
    var canRevert: Bool { original.map { $0.origin == .shipped } ?? false }
    /// Remove is on a custom rule only (RD-5).
    var canRemove: Bool { original.map { $0.origin == .custom } ?? false }
    var isBusy: Bool { state == .sending }

    var failure: ShellCopy? {
        if case .failed(let copy) = state { copy } else { nil }
    }

    /// Whether Save is on: the fields are valid, something changed, and
    /// nothing is being sent.
    var canSave: Bool {
        guard state != .sending, state != .done, isValid else { return false }
        guard let original else { return true }
        return saveRequest(from: original) != baseline(of: original)
    }

    private var isValid: Bool {
        if canEditName, trimmed(name).isEmpty { return false }
        if showsInstruction, trimmed(instruction).isEmpty { return false }
        return parameters.allSatisfy { Self.whole($0.text) != nil }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A whole number, 0 or more, or nil.
    private static func whole(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }

    // MARK: the requests

    /// What Save would send now: every field, each as it was unless edited.
    private func saveRequest(from version: RuleVersion) -> SaveRuleRequest {
        var values = version.parameters
        for field in parameters {
            if let value = Self.whole(field.text) {
                values = (values ?? [:]).merging([field.key: .number(Double(value))]) { _, new in new }
            }
        }
        return SaveRuleRequest(
            name: canEditName && name != version.name ? trimmed(name) : version.name,
            instruction: showsInstruction && instruction != (version.instruction ?? "")
                ? trimmed(instruction) : version.instruction,
            parameters: values,
            scope: scopeKind == version.scope.kind ? version.scope : RuleScope(kind: scopeKind),
            onFail: showsOnFail ? onFail : version.onFail, route: version.route,
            queueTimeoutSeconds: version.queueTimeoutSeconds, runTimeoutSeconds: version.runTimeoutSeconds)
    }

    /// What Save sends when nothing was edited.
    private func baseline(of version: RuleVersion) -> SaveRuleRequest {
        SaveRuleRequest(
            name: version.name, instruction: version.instruction, parameters: version.parameters,
            scope: version.scope, onFail: version.onFail, route: version.route,
            queueTimeoutSeconds: version.queueTimeoutSeconds, runTimeoutSeconds: version.runTimeoutSeconds)
    }

    private var addRequest: AddRuleRequest {
        AddRuleRequest(
            name: trimmed(name), instruction: trimmed(instruction), hook: hook, scope: RuleScope(kind: scopeKind))
    }

    // MARK: the buttons

    /// Add rule, or Save rule. A key is kept while its command has not worked,
    /// so pressing again sends the same command, and dropped when the form
    /// changes, because the server refuses one key with two bodies.
    func save() async {
        guard canSave else { return }
        state = .sending
        do {
            switch mode {
            case .add:
                let request = addRequest
                let key = lastAdd?.request == request ? lastAdd!.key : IdempotencyKey()
                lastAdd = (request, key)
                _ = try await api.addRule(request, key: key).completedResult()
            case .change(let row):
                let request = saveRequest(from: row.version)
                let key = lastSave?.request == request ? lastSave!.key : IdempotencyKey()
                lastSave = (request, key)
                _ = try await api.saveRule(ruleID: row.rule.id, request, key: key).completedResult()
            }
            finish()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    /// Revert to default: the shipped fields as a new version.
    func revert() async {
        guard canRevert, case .change(let row) = mode, !isBusy, state != .done else { return }
        state = .sending
        do {
            let key = revertKey ?? IdempotencyKey()
            revertKey = key
            _ = try await api.revertRule(ruleID: row.rule.id, key: key).completedResult()
            finish()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    /// Remove a custom rule.
    func remove() async {
        guard canRemove, case .change(let row) = mode, !isBusy, state != .done else { return }
        state = .sending
        do {
            let key = removeKey ?? IdempotencyKey()
            removeKey = key
            _ = try await api.removeRule(ruleID: row.rule.id, key: key).completedResult()
            finish()
        } catch {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    private func finish() {
        state = .done
        onDone()
    }
}
