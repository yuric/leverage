import Foundation
import LeverageKit

struct AccountFacts: Sendable {
    struct Result: Sendable {
        var plan: String?
        var email: String?
    }

    typealias Read = @Sendable (ReaderAccount) async -> Result

    var read: Read

    init(read: @escaping Read) { self.read = read }

    init(testedCodexVersions: [String] = Provider.codex.testedToolVersions) {
        read = { account in
            switch Provider(rawValue: account.entry.id) {
            case .claude:
                return await Self.claude(account)
            case .codex:
                guard VersionGate.accepts(account.tool.version, testedVersions: testedCodexVersions),
                      let data = await CodexAppServer.account(account),
                      let reply = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                      let facts = reply["account"], facts["type"] == .string("chatgpt")
                else { return Result() }
                return Self.fields(plan: facts["planType"], email: facts["email"])
            default:
                return Result()
            }
        }
    }

    private static func claude(_ account: ReaderAccount) async -> Result {
        let timeLeft = account.deadline - ContinuousClock.now
        guard !Task.isCancelled, timeLeft > .zero, account.accountFolder != nil,
              let arguments = account.entry.status.value.arguments,
              let status = try? await Subprocess.run(.init(
                executable: account.tool.path, arguments: arguments, environment: account.environment,
                workingDirectory: account.workingDirectory.path, timeLimit: timeLeft,
                gracePeriod: .seconds(1), maximumOutputBytes: 64 << 10)),
              status.succeeded, !status.outputTruncated, !Task.isCancelled
        else { return Result() }
        return claudeStatus(status.standardOutput)
    }

    static func claudeStatus(_ data: Data) -> Result {
        guard let reply = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              reply["loggedIn"] == .bool(true)
        else { return Result() }
        return fields(plan: reply["subscriptionType"], email: reply["email"])
    }

    private static func fields(plan: JSONValue?, email: JSONValue?) -> Result {
        Result(
            plan: plan?.stringValue.flatMap { $0.unicodeScalars.count <= 40 ? $0 : nil },
            email: email?.stringValue.flatMap { $0.unicodeScalars.count <= 254 ? $0 : nil })
    }
}
