import Foundation
import LeverageKit
import Testing

@testable import LeverageApp

@Suite("MCP settings")
struct MCPSettingsTests {
    @Test("the settings hold the running bundle's sibling executable and only the token placeholder")
    func settingsFromAppBundle() throws {
        let address = try #require(URL(string: "http://127.0.0.1:49172"))
        let app = URL(fileURLWithPath: "/Applications/Leverage \"Test\".app/Contents/MacOS/LeverageApp")
        let command = "/Applications/Leverage \"Test\".app/Contents/MacOS/LeverageMCP"
        let text = try #require(MCPSettings.text(apiURL: address, role: .orchestrator, executableURL: app))
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try #require(object["mcpServers"] as? [String: Any])
        let leverage = try #require(servers["leverage"] as? [String: Any])
        #expect(leverage["command"] as? String == command)
        #expect(leverage["args"] as? [String] == [])
        #expect(leverage["env"] as? [String: String] == [
            EnvironmentKeys.apiURL: address.absoluteString,
            EnvironmentKeys.seatRole: "orchestrator",
            EnvironmentKeys.seatToken: "PASTE-THE-TOKEN-HERE",
        ])
    }

    @Test("settings cannot invent an executable path when the running executable is unavailable")
    func noExecutablePath() throws {
        let address = try #require(URL(string: "http://127.0.0.1:49172"))
        #expect(MCPSettings.text(apiURL: address, role: .builder, executableURL: nil) == nil)
    }
}
