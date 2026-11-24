import Foundation

// Temporary source compatibility for the app and end-to-end callers as
// they move to the task contract in UI-1. The models have no goal on the wire.
extension TaskSummary {
    @available(*, deprecated, message: "Use details for task text.")
    public var goal: String { "" }

    @available(*, deprecated, message: "Use the initializer without goal.")
    public init(
        id: UUID, projectID: UUID? = nil, title: String, goal _: String, details: String? = nil,
        state: TaskState, round: Int = 0, holderSeatID: UUID? = nil, builderSeatID: UUID? = nil,
        leaseDueAt: Date? = nil, leaseTimeLeftWhilePaused: Int? = nil, minimumStrengthRank: Int? = nil,
        contractVersion: Int = 0, budgetCap: Decimal? = nil, spent: Decimal = 0, workReference: String? = nil,
        priority: Priority = .normal
    ) {
        self.init(
            id: id, projectID: projectID, title: title, details: details, state: state, round: round,
            holderSeatID: holderSeatID, builderSeatID: builderSeatID, leaseDueAt: leaseDueAt,
            leaseTimeLeftWhilePaused: leaseTimeLeftWhilePaused, minimumStrengthRank: minimumStrengthRank,
            contractVersion: contractVersion, budgetCap: budgetCap, spent: spent, workReference: workReference,
            priority: priority)
    }
}

extension AddTaskRequest {
    @available(*, deprecated, message: "Use the initializer without goal.")
    public init(
        title: String, goal _: String, details: String? = nil, criteria: [CriterionInput]? = nil,
        actions: [ActionInput]? = nil, projectID: UUID? = nil, priority: Priority? = nil,
        workReference: String? = nil, state: TaskState? = nil
    ) {
        self.init(
            title: title, details: details, criteria: criteria, actions: actions, projectID: projectID,
            priority: priority, workReference: workReference, state: state)
    }
}

extension CompleteContractRequest {
    @available(*, deprecated, message: "Use details for task text.")
    public var goal: String { "" }

    @available(*, deprecated, message: "Use the initializer without goal.")
    public init(
        title: String, goal _: String, details: String?, criteria: [CriterionInput], actions: [ActionInput] = [],
        minimumStrengthRank: Int? = nil, budgetCap: Decimal? = nil, workReference: String?
    ) {
        self.init(
            title: title, details: details, criteria: criteria, actions: actions,
            minimumStrengthRank: minimumStrengthRank, budgetCap: budgetCap, workReference: workReference)
    }
}
