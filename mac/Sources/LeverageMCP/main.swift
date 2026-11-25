import Foundation
import LeverageKit

if CommandLine.arguments.dropFirst() == ["--version"] {
    print("LeverageMCP \(leverageMacVersion)")
    exit(0)
}

let log = Log(component: "mcp")
// Before any call: what an earlier version's URL cache kept of this
// program's calls, a seat's token included.
LeftoverURLCache.remove()
do {
    let configuration = try MCPConfiguration(environment: ProcessInfo.processInfo.environment)
    let http = MCPHTTPClient(transport: HTTPTransport(
        baseURL: configuration.apiBaseURL, token: configuration.seatToken))
    let server = MCPServer(
        input: .standardInput, output: .standardOutput,
        caller: ToolCaller(transport: http.send), catalog: ToolCatalog(role: configuration.role),
        log: log, token: configuration.seatToken
    )
    try await server.run()
} catch let error as MCPConfiguration.Invalid {
    log.error(error.description)
    exit(2)
} catch {
    log.error("The MCP session ended after a stream error.")
    exit(1)
}
