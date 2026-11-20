import Foundation
import LeverageKit

/// An in-memory `AppRuntime` for the app's view model tests: the test sets
/// the states the services answer with and reads back what was asked of
/// them. It starts no process and touches no Keychain. Tests only:
/// LeverageApp may not import LeverageTestSupport.
public final class FakeAppRuntime: AppRuntime, @unchecked Sendable {
    public let fakeServer = FakeServer()
    public let fakeHelper = FakeHelper()
    public let fakeSessions = FakeSessionStore()
    public let fakeNotifier = FakeNotifier()
    public let fakeInboxCursor = FakeInboxCursorStore()

    public init() {}

    public var server: any ServerSupervising { fakeServer }
    public var helper: any HelperSupervising { fakeHelper }
    public var sessions: any SessionStoring { fakeSessions }
    public var notifier: any Notifying { fakeNotifier }
    public var inboxCursor: any InboxCursorStoring { fakeInboxCursor }
}

/// A value shared between the test and the code under test, behind a lock.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) { stored = value }

    public var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    public func update<Result>(_ change: (inout Value) -> Result) -> Result {
        lock.withLock { change(&stored) }
    }
}

public final class FakeServer: ServerSupervising, @unchecked Sendable {
    /// What `state()` answers.
    public let current = Locked(ServerState.notStarted)
    /// What `start()` moves to and answers.
    public let afterStart = Locked(ServerState.running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
    public let startCount = Locked(0)

    public init() {}

    public func state() async -> ServerState { current.value }

    public func start() async -> ServerState {
        startCount.update { $0 += 1 }
        current.value = afterStart.value
        return current.value
    }
}

public final class FakeHelper: HelperSupervising, @unchecked Sendable {
    public let current = Locked(HelperState.notStarted)
    public let afterStart = Locked(HelperState.running)
    /// The addresses `start` was called with, in order.
    public let starts = Locked<[URL]>([])
    public let tryAgainCount = Locked(0)
    public let stopCount = Locked(0)

    public init() {}

    public func state() async -> HelperState { current.value }

    public func start(apiBaseURL: URL, issuer: any HelperTokenIssuing) async -> HelperState {
        starts.update { $0.append(apiBaseURL) }
        current.value = afterStart.value
        return current.value
    }

    public func tryAgain() async -> HelperState {
        tryAgainCount.update { $0 += 1 }
        current.value = afterStart.value
        return current.value
    }

    public func stop() async {
        stopCount.update { $0 += 1 }
        current.value = .stopped
    }
}

/// `SessionStoring` in memory, for tests.
public final class FakeSessionStore: SessionStoring, @unchecked Sendable {
    public let token = Locked<String?>(nil)
    /// When set, every call throws it.
    public let failure = Locked<(any Error)?>(nil)

    public init() {}

    public func load() throws -> String? {
        if let error = failure.value { throw error }
        return token.value
    }

    public func save(_ token: String) throws {
        if let error = failure.value { throw error }
        self.token.value = token
    }

    public func clear() throws {
        if let error = failure.value { throw error }
        token.value = nil
    }
}
