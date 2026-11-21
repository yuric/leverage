import Foundation
import LeverageKit

/// MCP client settings built only from the executable path, API address, and agent role.
struct MCPSettings {
    private static let tokenPlaceholder = "PASTE-THE-TOKEN-HERE"

    let json: String
    let plainText: String

    init?(apiURL: URL, role: SeatRole, executableURL: URL? = Bundle.main.executableURL) {
        guard let executableURL else { return nil }
        let command = executableURL.deletingLastPathComponent().appendingPathComponent("LeverageMCP").path
        let environment = [
            EnvironmentKeys.apiURL: apiURL.absoluteString,
            EnvironmentKeys.seatRole: role.rawValue,
            EnvironmentKeys.seatToken: Self.tokenPlaceholder,
        ]
        let leverage: [String: Any] = ["command": command, "args": [String](), "env": environment]
        let config = ["mcpServers": ["leverage": leverage]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        json = String(decoding: data, as: UTF8.self)
        let variables = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        plainText = ([command] + variables).joined(separator: "\n")
    }

    static func text(apiURL: URL, role: SeatRole, executableURL: URL? = Bundle.main.executableURL) -> String? {
        Self(apiURL: apiURL, role: role, executableURL: executableURL)?.json
    }

    static func liveAPIAddress(from server: any ServerSupervising) async -> URL? {
        guard case .running(let url) = await server.state() else { return nil }
        return url
    }
}
