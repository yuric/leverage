import Foundation

// What the app's screens depend on to start the server and the helper and to
// keep the owner's session. LeverageAppServices implements these on the Mac;
// tests use LeverageTestSupport's FakeAppRuntime; and where the services are
// not built, UnavailableRuntime reports every service as not started.

/// Where the server on this Mac stands (plan PK-2, PK-3).
public enum ServerState: Equatable, Sendable {
    case notStarted
    /// No `docker` program was found.
    case dockerMissing
    /// Docker Desktop is installed and was asked to start.
    case dockerStarting
    /// Docker Desktop did not start in time; the owner opens it by hand.
    case dockerNotStarting
    /// The API image is not in this Mac's Docker.
    case imageMissing
    /// `docker compose up` ran; waiting for the health check.
    case starting
    /// The API answers its health check at this address.
    case running(apiBaseURL: URL)
    /// Anything else, with a line for the log (never shown as is).
    case failed(reason: String)
}

/// Where the helper stands (plan PK-4).
public enum HelperState: Equatable, Sendable {
    case notStarted
    case starting
    case running
    /// It exited with code 3 (its token ended) and is being started again.
    case restarting(attempt: Int)
    /// It failed to start three times in a minute; the owner can try again.
    case stoppedTrying
    /// It was stopped, as when the app quits.
    case stopped
}

/// Starts the server and reports its state.
public protocol ServerSupervising: AnyObject, Sendable {
    func state() async -> ServerState
    /// Starts what is not running yet and returns the state it reached.
    func start() async -> ServerState
}

/// Starts, restarts and stops the helper.
public protocol HelperSupervising: AnyObject, Sendable {
    func state() async -> HelperState
    /// Issues the helper's token through `issuer` and starts the helper.
    func start(apiBaseURL: URL, issuer: any HelperTokenIssuing) async -> HelperState
    /// After `stoppedTrying`: starts counting again and starts the helper.
    func tryAgain() async -> HelperState
    /// Asks the helper to stop and waits for it, at most ten seconds.
    func stop() async
}

/// Keeps the owner's session token between launches.
public protocol SessionStoring: AnyObject, Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}

/// The one server call the app services make: `issue_helper_token`.
public protocol HelperTokenIssuing: Sendable {
    /// Sends `issue_helper_token` with `name` and `idempotencyKey`. Returns
    /// the token from a `HelperTokenIssued` answer, or nil for a
    /// `HelperTokenIssuedRepeated` answer, which carries none.
    func issueHelperToken(name: String, idempotencyKey: String) async throws -> String?
}

/// One macOS notification about a Needs you item (HM-30): the item's
/// heading and its sentence, with the task's title and the account's name
/// and never an email.
public struct OwnerNotification: Equatable, Sendable {
    /// The Needs you item it is about; a click reports it.
    public let itemID: UUID
    public let title: String
    public let body: String

    public init(itemID: UUID, title: String, body: String) {
        self.itemID = itemID
        self.title = title
        self.body = body
    }
}

/// Tells the owner a Needs you item opened (HM-27 to HM-31). The real one
/// is `UserNotifier`; where none is made (tests, `swift run`, Linux) the app
/// gets `SilentNotifier`.
public protocol Notifying: AnyObject, Sendable {
    /// Asks the system for permission, once the app is signed in (HM-28);
    /// whether it was given.
    func requestPermission() async -> Bool
    /// Whether permission is given now. Asks nothing.
    func isPermitted() async -> Bool
    /// Shows one notification, also while the app is in front (HM-31).
    func post(_ notification: OwnerNotification) async
    /// What a click on a notification does: it is handed the item's id, and
    /// the app opens the Needs you tab. nil removes it.
    func onClick(_ handler: (@Sendable (UUID) -> Void)?)
}

/// Keeps the one number the inbox watcher needs to outlive the app: the
/// highest `inbox.opened` `seq` it announced (HM-29). No secret.
public protocol InboxCursorStoring: AnyObject, Sendable {
    /// The stored number; 0 when none was stored or it cannot be read.
    func load() -> Int
    func save(_ seq: Int) throws
}

/// The services the app runs with.
public protocol AppRuntime: Sendable {
    var server: any ServerSupervising { get }
    var helper: any HelperSupervising { get }
    var sessions: any SessionStoring { get }
    var notifier: any Notifying { get }
    var inboxCursor: any InboxCursorStoring { get }
}

extension AppRuntime {
    /// A runtime that names no notifier posts nothing.
    public var notifier: any Notifying { SilentNotifier.shared }
    /// A runtime that names no cursor store keeps the cursor in memory.
    public var inboxCursor: any InboxCursorStoring { InMemoryInboxCursor.shared }
}

/// The notifier that posts nothing. Permission is never given, so the app's
/// own line says notifications are off (HM-28).
public final class SilentNotifier: Notifying {
    public static let shared = SilentNotifier()

    public init() {}

    public func requestPermission() async -> Bool { false }
    public func isPermitted() async -> Bool { false }
    public func post(_ notification: OwnerNotification) async {}
    public func onClick(_ handler: (@Sendable (UUID) -> Void)?) {}
}

/// A cursor kept in memory: gone when the app quits.
public final class InMemoryInboxCursor: InboxCursorStoring, @unchecked Sendable {
    public static let shared = InMemoryInboxCursor()

    private let lock = NSLock()
    private var stored = 0

    public init() {}

    public func load() -> Int { lock.withLock { stored } }
    public func save(_ seq: Int) throws { lock.withLock { stored = seq } }
}

/// The runtime where the services are not built: every service reports
/// that it is not started, and no session is kept.
public struct UnavailableRuntime: AppRuntime {
    public init() {}

    public let server: any ServerSupervising = UnavailableServer()
    public let helper: any HelperSupervising = UnavailableHelper()
    public let sessions: any SessionStoring = NoSessionStore()
    public let notifier: any Notifying = SilentNotifier()
    public let inboxCursor: any InboxCursorStoring = InMemoryInboxCursor()
}

private final class UnavailableServer: ServerSupervising {
    func state() async -> ServerState { .notStarted }
    func start() async -> ServerState { .notStarted }
}

private final class UnavailableHelper: HelperSupervising {
    func state() async -> HelperState { .notStarted }
    func start(apiBaseURL: URL, issuer: any HelperTokenIssuing) async -> HelperState { .notStarted }
    func tryAgain() async -> HelperState { .notStarted }
    func stop() async {}
}

private final class NoSessionStore: SessionStoring {
    func load() throws -> String? { nil }
    func save(_ token: String) throws {}
    func clear() throws {}
}
