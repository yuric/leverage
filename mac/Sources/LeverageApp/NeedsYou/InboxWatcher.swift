import Foundation
import LeverageKit
import Observation

/// Tells the owner each time a Needs you item opens, and keeps the count on
/// the Needs you tab (HM-28 to HM-31).
@MainActor
@Observable
final class InboxWatcher {
    enum Permission: Equatable, Sendable { case unknown, given, notGiven }

    private(set) var openCount = 0
    private(set) var permission: Permission = .unknown

    /// The line the Needs you screen carries when notifications are off.
    var notificationsAreOff: Bool { false }

    init(
        owner: any OwnerAPI, notifier: any Notifying, cursor: any InboxCursorStoring,
        select: @escaping @MainActor () -> Void, waitSeconds: Int = 25, idleDelay: Duration = .milliseconds(500),
        retryDelay: Duration = .seconds(2)
    ) {}

    func start() async {}
    func catchUp() async {}
    func handle(events: [EventRecord]) async {}
    func attach(to feed: EventFeed) {}
    func run() async {}
}
