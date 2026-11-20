import Foundation
import LeverageKit

/// `Notifying` on the macOS notification center (plan HM-27 to HM-31).
/// WP13 writes it. This first version posts nothing, like the form `make`
/// returns everywhere but in a real bundle.
public final class UserNotifier: Notifying {
    public init() {}

    /// The one place that decides which notifier the app gets: the real one
    /// only when `bundleURL` ends in `.app` and `LEVERAGE_NOTIFICATIONS` is
    /// not `off`, and otherwise the form that posts nothing. Making the real
    /// one calls nothing; the center is first touched when the app asks for
    /// permission. (First version: always the form that posts nothing.)
    public static func make(bundleURL: URL, environment: [String: String]) -> any Notifying {
        SilentNotifier.shared
    }

    public func requestPermission() async -> Bool { false }
    public func isPermitted() async -> Bool { false }
    public func post(_ notification: OwnerNotification) async {}
    public func onClick(_ handler: (@Sendable (UUID) -> Void)?) {}
}
