import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// The helper's inputs come from its environment (§2.4) and it fails
/// closed without its token (PK-4).
@Suite("Helper configuration")
struct HelperConfigurationTests {
    private let base = [
        "HOME": "/Users/standin", "PATH": "/usr/bin:/bin",
        EnvironmentKeys.apiURL: "http://127.0.0.1:47130",
    ]

    @Test("without the helper's token it refuses to start")
    func failsClosedWithoutToken() {
        #expect(throws: HelperConfiguration.Failure.missingHelperToken) {
            try HelperConfiguration(environment: base, executablePath: "/Applications/Leverage.app/Contents/MacOS/LeverageHelper")
        }
        var empty = base
        empty[EnvironmentKeys.helperToken] = ""
        #expect(throws: HelperConfiguration.Failure.missingHelperToken) {
            try HelperConfiguration(environment: empty, executablePath: "/x/LeverageHelper")
        }
    }

    @Test("the defaults: the runner beside the helper, the support folder in Application Support, no tool folder")
    func defaults() throws {
        var environment = base
        environment[EnvironmentKeys.helperToken] = MadeUp.helperToken

        let configuration = try HelperConfiguration(
            environment: environment, executablePath: "/Applications/Leverage.app/Contents/MacOS/LeverageHelper")

        #expect(configuration.helperToken == MadeUp.helperToken)
        #expect(configuration.settings.apiBaseURL == URL(string: "http://127.0.0.1:47130"))
        #expect(configuration.settings.runnerPath == "/Applications/Leverage.app/Contents/MacOS/LeverageRunner")
        #expect(configuration.settings.supportFolder.path == "/Users/standin/Library/Application Support/leverage")
        #expect(configuration.settings.toolDir == nil)
        // The token is the configuration's, never part of what children are built from.
        #expect(configuration.settings.environment[EnvironmentKeys.helperToken] == nil)
    }

    @Test("the environment's overrides are used")
    func overrides() throws {
        var environment = base
        environment[EnvironmentKeys.helperToken] = MadeUp.helperToken
        environment[EnvironmentKeys.runnerPath] = "/tmp/runner"
        environment[EnvironmentKeys.supportDir] = "/tmp/support"
        environment[EnvironmentKeys.toolDir] = "/tmp/tools"

        let configuration = try HelperConfiguration(environment: environment, executablePath: "/x/LeverageHelper")

        #expect(configuration.settings.runnerPath == "/tmp/runner")
        #expect(configuration.settings.supportFolder.path == "/tmp/support")
        #expect(configuration.settings.toolDir == "/tmp/tools")
    }

    @Test("a description of the configuration never shows the token")
    func descriptionHidesToken() throws {
        var environment = base
        environment[EnvironmentKeys.helperToken] = MadeUp.helperToken
        let configuration = try HelperConfiguration(environment: environment, executablePath: "/x/LeverageHelper")

        #expect(!String(describing: configuration).contains(MadeUp.helperToken))
        #expect(!String(reflecting: configuration).contains(MadeUp.helperToken))
    }

    @Test("the helper gives a stopped runner the shared stop grace")
    func stopGraceIsShared() {
        #expect(HelperTimings.standard.stopGrace == StopTimings.runnerStopGrace)
    }
}
