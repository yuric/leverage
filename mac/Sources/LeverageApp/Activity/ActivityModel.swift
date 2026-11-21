import LeverageKit
import Observation

@MainActor
@Observable
final class ActivityModel {
    enum Filter: Hashable {
        case important, everything
    }

    var filter: Filter = .important
    var entries: [LogEntry] { [] }
    var hasEarlier: Bool { false }

    init(api: any OwnerAPI) {}

    func load() async {}
    func showEarlier() async {}
    func attach(to feed: EventFeed) {}
    func detach() {}
}
