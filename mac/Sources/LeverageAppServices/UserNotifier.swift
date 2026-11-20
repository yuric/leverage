import Foundation
import LeverageKit

#if canImport(UserNotifications)
import UserNotifications
#endif

/// `Notifying` on the macOS notification center (plan HM-27 to HM-31).
///
/// Making one calls nothing: `UNUserNotificationCenter.current()` raises an
/// uncaught exception in a program that is not inside an app bundle, so the
/// center is first touched when the app asks for permission, and `make` is
/// the one place that decides whether this type is made at all.
public final class UserNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (UUID) -> Void)?
    #if canImport(UserNotifications)
    private var delegate: CenterDelegate?
    #endif

    public init() {}

    /// The one place that decides which notifier the app gets: the real one
    /// only when `bundleURL` ends in `.app` and `LEVERAGE_NOTIFICATIONS` is
    /// not `off`, and otherwise the form that posts nothing. Making the real
    /// one calls nothing; the center is first touched when the app asks for
    /// permission. Both inputs are arguments, so a test passes made values
    /// and no global is read.
    public static func make(bundleURL: URL, environment: [String: String]) -> any Notifying {
        let isBundle = bundleURL.pathExtension.lowercased() == "app"
        let value = environment[EnvironmentKeys.notifications] ?? ""
        let isOff = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off"
        guard isBundle, !isOff else { return SilentNotifier.shared }
        return UserNotifier()
    }

    // MARK: - What a notification carries

    static let itemKey = "itemID"

    /// What a notification carries so a click can name its item: the id and
    /// nothing else (the words are the notification's own title and body).
    static func userInfo(for notification: OwnerNotification) -> [String: String] {
        [itemKey: notification.itemID.uuidString]
    }

    /// The item a clicked notification's `userInfo` names, or nil.
    static func itemID(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[itemKey] as? String).flatMap(UUID.init(uuidString:))
    }

    public func onClick(_ handler: (@Sendable (UUID) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// Hands a click's item to the handler `onClick` set.
    func deliverClick(userInfo: [AnyHashable: Any]) {
        guard let item = Self.itemID(from: userInfo) else { return }
        let current = lock.withLock { handler }
        current?(item)
    }

    #if canImport(UserNotifications)

    // MARK: - The center (never reached by a test)

    /// The first touch of the center: the delegate is set here, so that a
    /// notification is shown while the app is in front and a click comes
    /// back to `deliverClick`.
    private func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        lock.withLock {
            if delegate == nil {
                let made = CenterDelegate { [weak self] userInfo in self?.deliverClick(userInfo: userInfo) }
                delegate = made
                center.delegate = made
            }
        }
        return center
    }

    public func requestPermission() async -> Bool {
        do {
            return try await center().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func isPermitted() async -> Bool {
        let settings = await center().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        default: return false
        }
    }

    public func post(_ notification: OwnerNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.userInfo = Self.userInfo(for: notification)
        let request = UNNotificationRequest(
            identifier: notification.itemID.uuidString, content: content, trigger: nil)
        try? await center().add(request)
    }

    private final class CenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        private let clicked: @Sendable ([AnyHashable: Any]) -> Void

        init(clicked: @escaping @Sendable ([AnyHashable: Any]) -> Void) {
            self.clicked = clicked
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            clicked(response.notification.request.content.userInfo)
            completionHandler()
        }
    }

    #else

    public func requestPermission() async -> Bool { false }
    public func isPermitted() async -> Bool { false }
    public func post(_ notification: OwnerNotification) async {}

    #endif
}
