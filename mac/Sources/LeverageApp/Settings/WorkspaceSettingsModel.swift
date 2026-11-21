import LeverageKit

@MainActor
final class WorkspaceSettingsModel {
    enum Field: CaseIterable {
        case leaseLength, checkQueueTimeout, checkRunTimeout, maximumRounds, rerunLimit, recoveryTimeCeiling
    }

    var fields: [Field: String] = [:]
    var canSave: Bool { false }

    init(api: any OwnerAPI) {}

    func load() async {}
    func save() async {}
    func attach(to feed: EventFeed) {}
    func detach() {}
}
