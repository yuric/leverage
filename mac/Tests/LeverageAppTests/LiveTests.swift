import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

/// What `Live` reads from the app bundle, and the runtime it builds from it
/// (plan PK-1, PK-8). Nothing here starts Docker, the helper or a Keychain
/// call: the session store is always the memory one, and the support folder
/// is a temporary one.
@Suite("Live runtime")
struct LiveTests {
    private let bundle = URL(fileURLWithPath: "/Applications/Made Up/Leverage.app", isDirectory: true)

    private var resources: URL { bundle.appendingPathComponent("Contents/Resources", isDirectory: true) }
    private var executable: URL { bundle.appendingPathComponent("Contents/MacOS/LeverageApp") }

    @Test("the bundle's compose file, image tag and helper are where build_app.sh puts them")
    func settingsFromTheBundle() {
        let settings = LiveSettings(
            info: [LiveSettings.imageTagKey: "0.1.0"], resources: resources, executable: executable)
        #expect(settings.composeSource.path == "/Applications/Made Up/Leverage.app/Contents/Resources/compose.yaml")
        #expect(settings.imageTag == "0.1.0")
        #expect(settings.helperProgram.path == "/Applications/Made Up/Leverage.app/Contents/MacOS/LeverageHelper")
    }

    @Test("outside a bundle, or with a tag Docker would refuse, the tag is compose.yaml's own default")
    func imageTagFallsBack() {
        for info: [String: Any] in [
            [:], [LiveSettings.imageTagKey: ""], [LiveSettings.imageTagKey: "has space"],
            [LiveSettings.imageTagKey: "-leading-dash"], [LiveSettings.imageTagKey: 7],
            [LiveSettings.imageTagKey: String(repeating: "a", count: 129)],
        ] {
            let settings = LiveSettings(info: info, resources: resources, executable: executable)
            #expect(settings.imageTag == "local")
        }
        #expect(LiveSettings.fallbackImageTag == "local")
    }

    @Test("a tag of letters, digits, dots, dashes and underscores is kept")
    func imageTagKept() {
        for tag in ["m2-rc", "0.1.0", "v1_2", "A"] {
            #expect(LiveSettings(info: [LiveSettings.imageTagKey: tag], resources: resources, executable: executable)
                .imageTag == tag)
        }
    }

    @Test("the runtime starts nothing when it is made, and keeps the session in memory when asked")
    func runtimeStartsNothing() async throws {
        let folder = try TemporaryFolder(prefix: "leverage-live")
        defer { folder.remove() }
        let environment = [
            EnvironmentKeys.supportDir: folder.url.path, EnvironmentKeys.sessionStore: "memory",
        ]
        let settings = LiveSettings(info: [:], resources: resources, executable: executable)
        let runtime = try Live.make(settings: settings, environment: environment, home: folder.url)

        #expect(await runtime.server.state() == .notStarted)
        #expect(await runtime.helper.state() == .notStarted)
        if Live.servicesAreBuilt {
            try runtime.sessions.save("made-up-session-token")
            #expect(try runtime.sessions.load() == "made-up-session-token")
            try runtime.sessions.clear()
            #expect(try runtime.sessions.load() == nil)
            // The support folder now holds the lock and nothing else of the server's.
            #expect(FileManager.default.fileExists(atPath: folder.path("app.lock").path))
            #expect(!FileManager.default.fileExists(atPath: folder.path("server").path))
        }
    }

    @Test("the settings name the bundle the app runs from, which the notifier is decided on (HM-27)")
    func settingsNameTheBundle() {
        let settings = LiveSettings(
            info: [:], resources: resources, executable: executable, bundleURL: bundle)
        #expect(settings.bundleURL == bundle)
        // Outside a bundle (swift run, a test) the folder of the program is not an app.
        let loose = URL(fileURLWithPath: "/tmp/made-up/.build/debug/LeverageApp")
        let unbundled = LiveSettings(
            info: [:], resources: loose.deletingLastPathComponent(), executable: loose)
        #expect(unbundled.bundleURL.pathExtension != "app")
    }

    @Test("the runtime notifies only from an app bundle with notifications not turned off (HM-27)")
    func notifierFollowsTheBundle() throws {
        guard Live.servicesAreBuilt else { return }
        func notifier(bundleURL: URL, notifications: String?) throws -> any Notifying {
            let folder = try TemporaryFolder(prefix: "leverage-live")
            defer { folder.remove() }
            var environment = [EnvironmentKeys.supportDir: folder.url.path, EnvironmentKeys.sessionStore: "memory"]
            environment[EnvironmentKeys.notifications] = notifications
            let settings = LiveSettings(
                info: [:], resources: resources, executable: executable, bundleURL: bundleURL)
            // Making the real notifier touches no notification center (HM-27).
            return try Live.make(settings: settings, environment: environment, home: folder.url).notifier
        }
        #expect(!(try notifier(bundleURL: bundle, notifications: nil) is SilentNotifier))
        #expect(try notifier(bundleURL: bundle, notifications: "off") is SilentNotifier)
        let loose = URL(fileURLWithPath: "/tmp/made-up/.build/debug", isDirectory: true)
        #expect(try notifier(bundleURL: loose, notifications: nil) is SilentNotifier)
    }

    @Test("the inbox cursor is kept in the support folder and outlives the runtime (HM-29)")
    func cursorOutlivesTheRuntime() throws {
        guard Live.servicesAreBuilt else { return }
        let folder = try TemporaryFolder(prefix: "leverage-live")
        defer { folder.remove() }
        let environment = [
            EnvironmentKeys.supportDir: folder.url.path, EnvironmentKeys.sessionStore: "memory",
        ]
        let settings = LiveSettings(info: [:], resources: resources, executable: executable)

        var first: (any AppRuntime)? = try Live.make(settings: settings, environment: environment, home: folder.url)
        #expect(first?.inboxCursor !== InMemoryInboxCursor.shared)
        #expect(first?.inboxCursor.load() == 0)
        try first?.inboxCursor.save(42)
        first = nil
        #expect(first == nil)

        let file = folder.path("inbox-cursor")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let second = try Live.make(settings: settings, environment: environment, home: folder.url)
        #expect(second.inboxCursor.load() == 42)
    }

    @Test("a second copy on the same support folder is told which copy holds it, until that one is gone")
    func oneCopyPerSupportFolder() throws {
        guard Live.servicesAreBuilt else { return }
        let folder = try TemporaryFolder(prefix: "leverage-live")
        defer { folder.remove() }
        let environment = [
            EnvironmentKeys.supportDir: folder.url.path, EnvironmentKeys.sessionStore: "memory",
        ]
        let settings = LiveSettings(info: [:], resources: resources, executable: executable)

        var first: (any AppRuntime)? = try Live.make(settings: settings, environment: environment, home: folder.url)
        _ = withExtendedLifetime(first) {
            #expect(throws: LiveError.heldByAnotherCopy(processID: getpid())) {
                _ = try Live.make(settings: settings, environment: environment, home: folder.url)
            }
        }
        first = nil
        #expect(first == nil)
        let third = try Live.make(settings: settings, environment: environment, home: folder.url)
        _ = third
    }

    @Test("each support folder has its own lock")
    func separateFoldersDoNotClash() throws {
        guard Live.servicesAreBuilt else { return }
        let one = try TemporaryFolder(prefix: "leverage-live")
        let two = try TemporaryFolder(prefix: "leverage-live")
        defer { one.remove(); two.remove() }
        let settings = LiveSettings(info: [:], resources: resources, executable: executable)
        let first = try Live.make(
            settings: settings,
            environment: [EnvironmentKeys.supportDir: one.url.path, EnvironmentKeys.sessionStore: "memory"],
            home: one.url)
        let second = try Live.make(
            settings: settings,
            environment: [EnvironmentKeys.supportDir: two.url.path, EnvironmentKeys.sessionStore: "memory"],
            home: two.url)
        withExtendedLifetime((first, second)) {}
    }
}

/// LeverageTestSupport's runtime fakes can be made on their own, outside
/// FakeAppRuntime (WP14's request).
@Suite("Runtime fakes")
struct RuntimeFakesTests {
    @Test("FakeServer, FakeHelper and FakeSessionStore have public initialisers")
    func fakesAreConstructible() async throws {
        let server = FakeServer()
        let helper = FakeHelper()
        let sessions = FakeSessionStore()
        #expect(await server.state() == .notStarted)
        #expect(await helper.state() == .notStarted)
        try sessions.save("made-up-session-token")
        #expect(try sessions.load() == "made-up-session-token")
    }
}
