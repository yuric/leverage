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
    static let offeredHooks: [RuleHook] = []
    /// The two scopes offered now (RD-22).
    static let offeredScopes: [RuleScopeKind] = []

    let mode: Mode
    private(set) var state: State = .editing

    var name = ""
    var instruction = ""
    var hook: RuleHook = .taskBeforeReady
    var scopeKind: RuleScopeKind = .allTasks
    var onFail: RuleOnFail?
    var parameters: [ParameterField] = []

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let onDone: @MainActor () -> Void

    init(mode: Mode, api: any OwnerAPI, onDone: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.api = api
        self.onDone = onDone
    }

    var canEditName: Bool { false }
    var showsInstruction: Bool { false }
    var showsScope: Bool { false }
    var showsOnFail: Bool { false }
    var showsHook: Bool { false }
    var canRevert: Bool { false }
    var canRemove: Bool { false }
    var canSave: Bool { false }
    var failure: ShellCopy? { nil }

    func save() async {}
    func revert() async {}
    func remove() async {}
}
