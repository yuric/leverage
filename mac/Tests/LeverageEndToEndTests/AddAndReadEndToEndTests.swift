import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@Suite(.enabled(if: credentialsEnabled), .timeLimit(.minutes(Patience.minutes(5))))
struct AddAndReadEndToEndTests {
    private struct Login: Sendable {
        let provider: Provider
        let name: String
        let id = UUID()
    }

    @Test("Add schedules a first read, Refresh preserves sign-in, and Verify finds a sign-out")
    func testAddAndRead() async throws {
        let rig = try await CredentialsHarness.start(name: "add-and-read")
        try await withCleanup {
            try await checkLogins(rig)
        } cleanup: {
            await rig.stop()
        }
    }

    private func checkLogins(_ rig: CredentialsHarness) async throws {
        let claudeOne = Login(provider: .claude, name: "Claude One")
        let claudeTwo = Login(provider: .claude, name: "Claude Two")
        let codexOne = Login(provider: .codex, name: "Codex One")
        let codexTwo = Login(provider: .codex, name: "Codex Two")
        let gemini = Login(provider: .gemini, name: "Gemini")
        let grok = Login(provider: .grok, name: "Grok")
        let logins = [claudeOne, claudeTwo, codexOne, codexTwo, gemini, grok]
        let ids = Set(logins.map(\.id))
        let hasCodex = !Provider.codex.testedToolVersions.isEmpty
        let hasClaude = !Provider.claude.testedToolVersions.isEmpty
        var usage: [StandInScenario.UsageDirective] = []
        if let version = Provider.codex.testedToolVersions.first {
            usage.append(.init(tool: "codex", version: "codex-cli \(version)"))
            for (login, fixture) in [(codexOne, "resets-with-expiry"), (codexTwo, "resets-zero")] {
                usage.append(.init(tool: "codex", account: rig.handoffWorld.accountFolder(login.id),
                                   reply: try codexReply(fixture, tools: rig.tools)))
            }
        }
        if let version = Provider.claude.testedToolVersions.first {
            usage.append(.init(tool: "claude", version: "\(version) (Claude Code)"))
            usage.append(.init(tool: "claude", account: rig.handoffWorld.accountFolder(claudeOne.id),
                               settings: "claude/usage-settings-empty-list.json"))
        }
        try rig.tools.write(scenario: .init(usage: usage))
        for login in logins {
            if login.provider == .gemini {
                try await addGemini(login, rig: rig)
            } else {
                _ = try await rig.handoffWorld.addLogin(login.provider, name: login.name, id: login.id)
            }
            _ = try await rig.follower.wait(for: "credential.added", deadline: CredentialsHarness.deadline) {
                $0.type == .credentialAdded && $0.subjectID == login.id
            }
            try await eventually("the first reading for \(login.name)", deadline: CredentialsHarness.deadline) {
                try await rig.owner.credentials().credentials.first { $0.credential.id == login.id }?.reading != nil
            }
        }
        let first = try await rig.owner.credentials()
        let rows = Dictionary(uniqueKeysWithValues: first.credentials.map { ($0.credential.id, $0) })
        #expect(Set(rows.keys) == ids)
        for login in logins {
            let row = try #require(rows[login.id])
            let reading = try #require(row.reading)
            switch login.provider {
            case .claude:
                #expect(row.credential.plan == "standin-claude-plan")
                #expect(row.credential.accountEmail == StandIns.statusEmail)
            case .codex where hasCodex:
                #expect(row.credential.plan == "standin-codex-plan")
                #expect(row.credential.accountEmail == StandIns.statusEmail)
            default:
                #expect(row.credential.plan == nil && row.credential.accountEmail == nil)
            }
            let hasReader = (login.provider == .codex && hasCodex) || (login.provider == .claude && hasClaude)
            if hasReader {
                #expect(reading.state == .ok)
                #expect(!reading.figures.isEmpty)
            } else {
                #expect(reading.state == .unavailable)
                #expect(reading.figures.isEmpty && reading.resets == nil)
            }
        }
        if hasCodex {
            #expect(rows[codexOne.id]?.reading?.figures != rows[codexTwo.id]?.reading?.figures)
            #expect(rows[codexOne.id]?.reading?.resets?.reduce(0) { $0 + $1.count } == 2)
            #expect(rows[codexTwo.id]?.reading?.resets?.reduce(0) { $0 + $1.count } == 0)
        }
        if hasClaude {
            #expect(rows[claudeOne.id]?.reading?.figures != rows[claudeTwo.id]?.reading?.figures)
            #expect(rows[claudeOne.id]?.reading?.resets?.reduce(0) { $0 + $1.count } == 0)
            #expect(rows[claudeTwo.id]?.reading?.resets == nil)
        }

        let beforeRefresh = try rig.tools.calls().count
        for _ in 0..<3 {
            let refreshed = try await finish(rig.owner.refreshUsage(key: IdempotencyKey()), owner: rig.owner)
            #expect(Set(refreshed.compactMap(\.credentialID)) == ids)
            #expect(refreshed.allSatisfy { $0.kind == .readUsage && $0.state == .finished })
        }
        if hasCodex {
            let before = try await rig.owner.credentials()
            let account = rig.handoffWorld.accountFolder(codexTwo.id)
            usage.removeAll { $0.tool == "codex" && $0.account == account.path }
            usage.append(.init(tool: "codex", account: account, neverAnswers: true))
            try rig.tools.write(scenario: .init(usage: usage))
            let refreshed = try await finish(rig.owner.refreshUsage(key: IdempotencyKey()), owner: rig.owner)
            let hung = try #require(refreshed.first { $0.credentialID == codexTwo.id })
            #expect(hung.state == .failed)
            #expect(hung.result?.checks.last?.failure == .timedOut)
            let after = try await rig.owner.credentials()
            let afterRows = Dictionary(uniqueKeysWithValues: after.credentials.map { ($0.credential.id, $0) })
            #expect(afterRows[codexTwo.id]?.reading?.state == .unavailable)
            for row in before.credentials where row.credential.id != codexTwo.id {
                let refreshed = try #require(afterRows[row.credential.id]?.reading)
                #expect(refreshed.state == row.reading?.state)
                #expect(refreshed.figures == row.reading?.figures)
                #expect(refreshed.resets == row.reading?.resets)
            }
            // Restore the scenario so Verify can read both accounts' facts.
            usage.removeAll { $0.tool == "codex" && $0.account == account.path }
            usage.append(.init(tool: "codex", account: account, reply: "codex/usage-e2e-resets-zero.json"))
            try rig.tools.write(scenario: .init(usage: usage))
        }
        let duringRefresh = try rig.tools.calls().dropFirst(beforeRefresh)
        let enabledTools = Set([hasCodex ? "codex" : nil, hasClaude ? "claude" : nil].compactMap { $0 })
        #expect(Set(duringRefresh.map(\.tool)) == enabledTools)
        #expect(duringRefresh.allSatisfy { call in
            call.argv == ["--version"] || call.argv == ["app-server"] ||
                call.argv == ["login", "status"] || call.argv.prefix(2) == ["auth", "status"] ||
                call.argv.contains("/usage")
        })

        try await verifyAll(rig.owner, ids: ids)
        try rig.handoffWorld.signOutInTool("claude", account: rig.handoffWorld.accountFolder(claudeTwo.id))
        try await verifyAll(rig.owner, ids: ids, signedOut: claudeTwo.id)

        let beforeSignIn = try await EventFollower.fromNow(owner: rig.owner)
        _ = try await rig.owner.followed("Sign in again", rig.owner.signInAgain(
            credentialID: claudeTwo.id, key: IdempotencyKey()), deadline: CredentialsHarness.deadline)
        _ = try await beforeSignIn.wait(for: "credential.verified", deadline: CredentialsHarness.deadline) {
            $0.type == .credentialVerified && $0.subjectID == claudeTwo.id
        }
        let after = try await rig.owner.credentials()
        #expect(after.credentials.allSatisfy { $0.credential.state == .active })

        let calls = try rig.tools.calls()
        let signIns = calls.filter { call in
            call.argv == ["auth", "login"] || call.argv.first == "login" && call.argv != ["login", "status"]
        }
        #expect(signIns.map(\.tool).sorted() == ["claude", "claude", "claude", "codex", "codex", "grok"])
        #expect(!calls.contains { $0.argv.contains("logout") || $0.argv.contains("signout") })
        let appServer = rig.tools.state.appendingPathComponent("app-server.jsonl")
        if hasCodex {
            let lines = try String(contentsOf: appServer, encoding: .utf8).split(separator: "\n")
            let messages = try lines.map {
                try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
            }
            let allowed = Set(["initialize", "initialized", "account/read", "account/rateLimits/read", "account/usage/read"])
            #expect(!messages.isEmpty)
            #expect(messages.allSatisfy { $0["method"]?.stringValue.map(allowed.contains) == true })
            #expect(messages.contains { $0["method"] == .string("account/read") })
            #expect(messages.contains { $0["method"] == .string("account/rateLimits/read") })
            #expect(messages.contains { $0["method"] == .string("account/usage/read") })
            for message in messages where message["method"] == .string("account/read") {
                #expect(message["params"]?["refreshToken"] == .bool(false))
            }
        }
        #expect(try rig.providerAPI.calls().isEmpty)
    }

    private func codexReply(_ name: String, tools: StandInTools) throws -> String {
        let source = tools.replies.appendingPathComponent("codex/usage-\(name).json")
        let dest = "codex/usage-e2e-\(name).json"
        // The checked-in reset fixtures have API-key account facts. Play the
        // other fixture's ChatGPT shape with the same made-up email as Claude.
        var fixture = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: source))
        guard case .object(var session) = fixture["session"] else {
            throw EndToEndFailure("the Codex usage fixture lacks a session")
        }
        session["account/read"] = .object(["result": .object(["account": .object([
            "type": .string("chatgpt"), "email": .string(StandIns.statusEmail),
            "planType": .string("standin-codex-plan"),
        ])])])
        if name == "resets-zero" {
            guard case .object(var result) = session["account/rateLimits/read"]?["result"],
                  case .object(var limits) = result["rateLimits"],
                  case .object(var primary) = limits["primary"] else {
                throw EndToEndFailure("the Codex usage fixture lacks its primary limit")
            }
            primary["usedPercent"] = .number(40)
            limits["primary"] = .object(primary)
            result["rateLimits"] = .object(limits)
            session["account/rateLimits/read"] = .object(["result": .object(result)])
        }
        fixture["session"] = .object(session)
        try JSONEncoder().encode(fixture).write(to: tools.replies.appendingPathComponent(dest), options: .atomic)
        return dest
    }

    private func addGemini(_ login: Login, rig: CredentialsHarness) async throws {
        let outcome = try await rig.owner.addCredential(
            .init(credentialID: login.id, provider: .gemini, name: login.name, strengthRank: 1),
            key: IdempotencyKey())
        let id = try #require(try outcome.completedResult()?.helperRequestID)
        let deadline = ContinuousClock.now + .seconds(CredentialsHarness.deadline)
        var changed: Date?
        while true {
            guard ContinuousClock.now < deadline else {
                throw EndToEndFailure("Gemini did not wait for sign-in")
            }
            let request = try await rig.owner.helperRequest(id: id, wait: 10, changedAfter: changed).request
            if request.progress.contains(where: { $0.check == .signedIn && $0.state == .waitingForSignIn }) {
                try rig.tools.signIn("agy")
                break
            }
            changed = request.updatedAt
        }
        let result = try await finishedRequest(id, owner: rig.owner, deadline: CredentialsHarness.deadline)
        #expect(result.state == .finished)
    }

    private func finish(_ outcome: CommandOutcome<QueuedRequests>, owner: OwnerClient) async throws -> [HelperRequest] {
        let requests = try #require(try outcome.completedResult())
        var ended: [HelperRequest] = []
        for id in requests.helperRequestIDs {
            ended.append(try await finishedRequest(id, owner: owner, deadline: CredentialsHarness.deadline))
        }
        return ended
    }

    private func verifyAll(_ owner: OwnerClient, ids: Set<UUID>, signedOut: UUID? = nil) async throws {
        let before = try await EventFollower.fromNow(owner: owner)
        let requests = try await finish(owner.verifyAllCredentials(key: IdempotencyKey()), owner: owner)
        #expect(Set(requests.compactMap(\.credentialID)) == ids)
        #expect(requests.allSatisfy { $0.state == ($0.credentialID == signedOut ? .failed : .finished) })
        for id in ids {
            let expected: EventType = id == signedOut ? .credentialSignedOut : .credentialVerified
            _ = try await before.wait(for: expected.rawValue, deadline: CredentialsHarness.deadline) {
                $0.type == expected && $0.subjectID == id
            }
        }
        let events = await before.seen.filter { [.credentialSignedOut, .credentialVerified].contains($0.type) }
        #expect(events.count == ids.count)
    }
}
