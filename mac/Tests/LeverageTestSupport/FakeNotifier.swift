import Foundation
import LeverageKit

/// A `Notifying` for tests: it shows nothing, keeps every notification it
/// was asked to post, and lets a test answer the permission question and
/// click a notification. It never touches the notification center.
public final class FakeNotifier: Notifying, @unchecked Sendable {
    /// What `requestPermission()` answers, and `isPermitted()` after it.
    public let permission = Locked(true)
    /// How many times permission was asked for.
    public let permissionRequests = Locked(0)
    /// Every notification posted, in order.
    public let posted = Locked<[OwnerNotification]>([])
    private let handler = Locked<(@Sendable (UUID) -> Void)?>(nil)

    public init() {}

    public func requestPermission() async -> Bool {
        permissionRequests.update { $0 += 1 }
        return permission.value
    }

    public func isPermitted() async -> Bool { permission.value }

    public func post(_ notification: OwnerNotification) async {
        posted.update { $0.append(notification) }
    }

    public func onClick(_ handler: (@Sendable (UUID) -> Void)?) {
        self.handler.value = handler
    }

    /// The owner clicks the notification of `itemID`. False when no handler
    /// is set.
    @discardableResult
    public func click(_ itemID: UUID) -> Bool {
        guard let handler = handler.value else { return false }
        handler(itemID)
        return true
    }
}
