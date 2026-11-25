import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ProcessTests {
    @Test func versionWorksWithoutToken() throws {
        let child = try MCPChild(arguments: ["--version"])
        defer { child.cleanUp() }

        #expect(try child.waitForExit() == 0)
        let output = try child.stdout.fileHandleForReading.readToEnd() ?? Data()
        let version = String(decoding: output, as: UTF8.self)
        #expect(version == "LeverageMCP \(leverageMacVersion)\n")
        #expect(try child.standardError().isEmpty)
    }

    @Test func missingTokenFailsClosed() throws {
        let address = "http://127.0.0.1:1"
        let child = try MCPChild(environment: [EnvironmentKeys.apiURL: address])
        defer { child.cleanUp() }

        // Keep stdin open so a server that starts anyway cannot pass on EOF.
        #expect(try child.waitForExit() != 0)
        #expect(try child.stdout.fileHandleForReading.readToEnd()?.isEmpty ?? true)
        let diagnostic = String(decoding: try child.standardError(), as: UTF8.self)
        let lines = diagnostic.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let explainsMissingToken = lines.count == 2 && lines.last?.isEmpty == true &&
            diagnostic.contains(EnvironmentKeys.seatToken)
        #expect(explainsMissingToken)
        let omitsConfiguredAddress = !diagnostic.contains(address)
        #expect(omitsConfiguredAddress)
    }

    @Test func anInvalidConfiguredRoleFailsClosedWithoutEchoingTheValue() throws {
        let suppliedRole = "fixture-unrecognized-role"
        let child = try MCPChild(environment: [
            EnvironmentKeys.apiURL: "http://127.0.0.1:1",
            EnvironmentKeys.seatToken: "fixture-seat-value",
            EnvironmentKeys.seatRole: suppliedRole
        ])
        defer { child.cleanUp() }
        #expect(try child.waitForExit() != 0)
        #expect(try child.stdout.fileHandleForReading.readToEnd()?.isEmpty ?? true)
        let diagnostic = String(decoding: try child.standardError(), as: UTF8.self)
        let describesInvalidRole = diagnostic.contains(EnvironmentKeys.seatRole) && !diagnostic.contains(suppliedRole)
        #expect(describesInvalidRole)
    }

    @Test func configuredGeneralSeatListsEveryTool() throws {
        let child = try MCPChild(environment: [
            EnvironmentKeys.apiURL: "http://127.0.0.1:1",
            EnvironmentKeys.seatToken: "fixture-seat-value",
            EnvironmentKeys.seatRole: "general",
        ])
        defer { child.cleanUp() }
        let client = ScriptedMCPClient(
            input: child.stdin.fileHandleForWriting, output: child.stdout.fileHandleForReading,
            timeout: .seconds(30))

        _ = try client.initialize()
        try client.send(["jsonrpc": "2.0", "id": 20, "method": "tools/list"])
        let reply = try #require(try client.receive() as? [String: Any])
        #expect(reply["id"] as? Int == 20)
        let result = try #require(reply["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 27)
        #expect(tools.compactMap { $0["name"] as? String } == AgentTools.all.map(\.id))

        try client.closeInput()
        #expect(try child.waitForExit() == 0)
    }

    @Test func unreachableAPIIsAToolErrorAndEOFEndsTheSession() throws {
        let endpoint = try UnreachableEndpoint()
        let fakeToken = "process-fixture-\(UUID().uuidString)"
        let child = try MCPChild(environment: [
            EnvironmentKeys.apiURL: endpoint.address,
            EnvironmentKeys.seatRole: "builder",
            EnvironmentKeys.seatToken: fakeToken,
        ])
        defer { child.cleanUp() }
        let client = ScriptedMCPClient(
            input: child.stdin.fileHandleForWriting, output: child.stdout.fileHandleForReading)

        // An unrecognized revision can contain arbitrary input. The fallback
        // must work and neither the response nor the revision log may leak it.
        let initialize = try client.initialize(protocolVersion: "unknown-\(fakeToken)")
        try expectTokenAbsent(initialize, token: fakeToken)
        let revision = (initialize["result"] as? [String: Any])?["protocolVersion"] as? String
        let negotiatedFallback = revision == "2025-06-18"
        #expect(negotiatedFallback)

        try client.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "get_next", "arguments": ["wait": 0]],
        ])
        guard let reply = try client.receive() as? [String: Any] else {
            throw MCPChild.Failure.missingReply
        }
        try expectTokenAbsent(reply, token: fakeToken)
        let tool = reply["result"] as? [String: Any]
        let isToolError = reply["jsonrpc"] as? String == "2.0" &&
            reply["id"] as? Int == 2 && tool?["isError"] as? Bool == true
        #expect(isToolError)
        let content = tool?["content"] as? [[String: Any]]
        let hasToolErrorContent = content?.count == 1 && content?.first?["type"] as? String == "text"
        #expect(hasToolErrorContent)

        // IDs are generally echoed. An ID containing this seat's token still
        // must never put it on the wire.
        try client.send(["jsonrpc": "2.0", "method": "ping", "id": "test-\(fakeToken)"])
        guard let ping = try client.receive() as? [String: Any] else {
            throw MCPChild.Failure.missingReply
        }
        try expectTokenAbsent(ping, token: fakeToken)
        let pingIsProtocolReply = ping["jsonrpc"] as? String == "2.0" &&
            (ping["result"] is [String: Any] || ping["error"] is [String: Any])
        #expect(pingIsProtocolReply)
        #expect(child.process.isRunning)

        try client.closeInput()
        #expect(try child.waitForExit() == 0)
        let stdoutEnded = try client.receive() == nil
        #expect(stdoutEnded)
        let stderr = String(decoding: try child.standardError(), as: UTF8.self)
        let stderrOmitsToken = !stderr.contains(fakeToken)
        #expect(stderrOmitsToken)
        withExtendedLifetime(endpoint) {}
    }

    private func expectTokenAbsent(_ object: [String: Any], token: String) throws {
        let rendered = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        // Assert the Boolean so a failure never prints the token or reply.
        let omitsToken = !rendered.contains(token)
        #expect(omitsToken)
    }
}

/// Foundation reaps the process before calling its termination handler.
private final class MCPChild {
    enum Failure: Error {
        case programNotFound
        case exitTimedOut
        case missingReply
        case socketUnavailable
    }

    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    private let stderr = Pipe()
    private let exited = DispatchSemaphore(value: 0)

    init(arguments: [String] = [], environment: [String: String] = [:]) throws {
        process.executableURL = try Self.program()
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
    }

    func waitForExit() throws -> Int32 {
        guard exited.wait(timeout: .now() + Patience.seconds(30)) == .success else {
            throw Failure.exitTimedOut
        }
        return process.terminationStatus
    }

    func standardError() throws -> Data {
        try stderr.fileHandleForReading.readToEnd() ?? Data()
    }

    func cleanUp() {
        try? stdin.fileHandleForWriting.close()
        // Foundation still owns this exact child while it reports the child
        // running. Its termination handler observes the reap after SIGKILL.
        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        if exited.wait(timeout: .now() + Patience.seconds(5)) != .success {
            Issue.record("LeverageMCP did not exit after SIGKILL")
        }
    }

    private static func program() throws -> URL {
        #if canImport(Darwin)
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else {
            throw Failure.programNotFound
        }
        let image = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
        #else
        let path = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        let image = URL(fileURLWithPath: path)
        #endif
        // macOS loads the suite from within a bundle. A Linux runner can
        // live directly beside the product.
        var folder = image.deletingLastPathComponent()
        while folder.path != "/" && folder.pathExtension != "xctest" {
            folder.deleteLastPathComponent()
        }
        let products = folder.pathExtension == "xctest"
            ? folder.deletingLastPathComponent() : image.deletingLastPathComponent()
        let executable = products.appendingPathComponent("LeverageMCP")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.programNotFound
        }
        return executable
    }
}

/// Reserve a loopback TCP port without listening so connections are refused.
private final class UnreachableEndpoint {
    private let descriptor: Int32
    let address: String

    init() throws {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw MCPChild.Failure.socketUnavailable }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw MCPChild.Failure.socketUnavailable }
            var socketAddress = sockaddr_in()
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            try withUnsafeMutablePointer(to: &socketAddress) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    guard bind(fd, address, length) == 0,
                          getsockname(fd, address, &length) == 0 else { throw MCPChild.Failure.socketUnavailable }
                }
            }
            descriptor = fd
            address = "http://127.0.0.1:\(UInt16(bigEndian: socketAddress.sin_port))"
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(descriptor) }
}
