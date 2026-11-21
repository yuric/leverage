import Foundation
import LeverageKit

/// The read-only subset of Codex app-server over JSON lines (RD-3).
enum CodexAppServer {
    enum Method: String, CaseIterable {
        case initialize = "initialize"
        case account = "account/read"
        case rateLimits = "account/rateLimits/read"
        case usage = "account/usage/read"
    }

    struct UsageReplies: Sendable {
        let rateLimits: Data
        let usage: Data
    }

    static func usage(_ account: ReaderAccount) async -> UsageReplies? {
        await withSession(account) { child in
            let rateLimits = try await request(.rateLimits, id: 2, child: child)
            let usage = try await request(.usage, id: 3, child: child)
            let encoder = JSONEncoder()
            return try UsageReplies(rateLimits: encoder.encode(rateLimits), usage: encoder.encode(usage))
        }
    }

    static func account(_ account: ReaderAccount) async -> Data? {
        await withSession(account) { child in
            let reply = try await request(
                .account, id: 2, params: .object(["refreshToken": .bool(false)]), child: child)
            return try JSONEncoder().encode(reply)
        }
    }

    private struct Message: Encodable {
        var id: Int?
        let method: String
        var params: JSONValue?
    }

    private enum SessionFailure: Error {
        case invalidReply
        case differentHome
    }

    private static func withSession<Response: Sendable>(
        _ account: ReaderAccount, read: (RunningSubprocess) async throws -> Response
    ) async -> Response? {
        let timeLeft = account.deadline - ContinuousClock.now
        guard !Task.isCancelled, timeLeft > .zero, let folder = account.accountFolder,
              let arguments = ProviderCatalog.loginUsage(for: .codex)?.arguments.value,
              let child = try? Subprocess.startSession(.init(
                executable: account.tool.path, arguments: arguments, environment: account.environment,
                workingDirectory: account.workingDirectory.path, timeLimit: timeLeft,
                gracePeriod: .seconds(1), maximumOutputBytes: 8 << 20))
        else { return nil }

        return await withTaskCancellationHandler {
            do {
                let initialized = try await request(.initialize, id: 1, params: .object([
                    "clientInfo": .object(["name": .string("leverage"), "version": .string(leverageMacVersion)]),
                ]), child: child)
                // Compare with the folder we supplied, allowing its canonical
                // spelling without resolving a path supplied by the server.
                guard let home = initialized["codexHome"]?.stringValue,
                      home == folder.path || home == folder.resolvingSymlinksInPath().path
                else { throw SessionFailure.differentHome }
                try await write(Message(method: "initialized"), to: child)
                let reply = try await read(child)
                child.closeInput()
                let result = await child.wait()
                return result.succeeded && !result.outputTruncated && !Task.isCancelled ? reply : nil
            } catch {
                child.closeInput()
                child.stop()
                _ = await child.wait()
                return nil
            }
        } onCancel: {
            child.stop()
        }
    }

    private static func write(_ message: Message, to child: RunningSubprocess) async throws {
        try Task.checkCancellation()
        try await child.writeLine(JSONEncoder().encode(message))
    }

    private static func request(
        _ method: Method, id: Int, params: JSONValue? = nil, child: RunningSubprocess
    ) async throws -> JSONValue {
        try await write(Message(id: id, method: method.rawValue, params: params), to: child)
        while let line = await child.readLine() {
            try Task.checkCancellation()
            guard let reply = try? JSONDecoder().decode([String: JSONValue].self, from: line) else {
                throw SessionFailure.invalidReply
            }
            // An unsolicited request can use the same id. The helper never
            // answers a server request or handles a notification.
            guard reply["method"] == nil, reply["id"] == .number(Double(id)) else { continue }
            guard reply["error"] == nil, let result = reply["result"], result.objectValue != nil else {
                throw SessionFailure.invalidReply
            }
            return result
        }
        throw SessionFailure.invalidReply
    }
}
