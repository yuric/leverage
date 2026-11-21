import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

@Suite("Login account facts", .timeLimit(.minutes(Patience.minutes(1))))
struct AccountFactsTests {
    @Test("Verify returns Claude's plan and email without logging the status reply")
    func claudeFacts() async throws {
        let rig = try HelperRig()
        let credential = UUID()
        let folder = try rig.folders.createFresh(for: credential)
        try rig.tools.signIn("claude", accountFolder: folder)
        let tool = rig.tools.tool("claude")
        let original = rig.tools.tool("claude-original")
        try FileManager.default.moveItem(at: tool, to: original)
        let script = """
        #!/bin/sh
        if [ "$1" = auth ] && [ "$2" = status ]; then
          printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max","email":"\(StandIns.statusEmail)","orgName":"\(StandIns.statusOrganisation)"}'
        else
          exec "$(dirname "$0")/claude-original" "$@"
        fi
        """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let log = CapturedLog()

        let result = await verify(.claude, credential: credential, rig: rig, log: log.log)

        #expect(result.outcome == .finished)
        #expect(result.plan == "max")
        #expect(result.accountEmail == StandIns.statusEmail)
        #expect(!log.text.contains(StandIns.statusEmail))
        #expect(!log.text.contains(StandIns.statusOrganisation))
        #expect(!log.text.contains("subscriptionType"))
    }

    @Test("Verify reads facts only for a known Codex version", arguments: [true, false])
    func codexFacts(known: Bool) async throws {
        let rig = try HelperRig()
        let credential = UUID()
        let folder = try rig.folders.createFresh(for: credential)
        try rig.tools.signIn("codex", accountFolder: folder)
        try rig.tools.write(scenario: .init(usage: [
            .init(tool: "codex", version: known ? "codex-cli 0.169.0" : "codex-cli 0.1.0"),
            .init(tool: "codex", account: folder, reply: "codex/usage-both-windows.json"),
        ]))
        let log = CapturedLog()

        let result = await verify(.codex, credential: credential, rig: rig, log: log.log)

        #expect(result.outcome == .finished)
        let calls = try rig.tools.calls()
        #expect(calls.filter { $0.argv == ["app-server"] }.count == (known ? 1 : 0))
        if known {
            let reply = try LoginReaderFixtureTests.Reply.load(
                StandIns.replies.appendingPathComponent("codex/usage-both-windows.json"))
            struct AccountResult: Decodable {
                struct Account: Decodable {
                    let planType: String
                    let email: String
                }

                let account: Account
            }
            let account = try JSONDecoder().decode(AccountResult.self, from: reply.result(for: "account/read")).account
            #expect(result.plan == account.planType)
            #expect(result.accountEmail == account.email)
            #expect(!log.text.contains(account.email))
            #expect(!log.text.contains("requiresOpenaiAuth"))
        } else {
            #expect(result.plan == nil)
            #expect(result.accountEmail == nil)
        }
    }

    @Test("Gemini and Grok Verify return neither account fact", arguments: [Provider.gemini, .grok])
    func providersWithoutFacts(provider: Provider) async throws {
        let rig = try HelperRig()
        let credential = UUID()
        try rig.tools.signIn(provider == .gemini ? "agy" : "grok")
        let log = CapturedLog()

        let result = await verify(provider, credential: credential, rig: rig, log: log.log)

        #expect(result.outcome == .finished)
        #expect(result.plan == nil)
        #expect(result.accountEmail == nil)
        #expect(!log.text.contains(StandIns.statusEmail))
    }

    @Test("Claude status drops oversized fields independently and ignores signed-out replies")
    func fieldBounds() {
        let longPlan = String(repeating: "p", count: 41)
        let longEmail = String(repeating: "e", count: 255)
        let planTooLong = AccountFacts.claudeStatus(Data("""
            {"loggedIn":true,"subscriptionType":"\(longPlan)","email":"\(StandIns.statusEmail)"}
            """.utf8))
        #expect(planTooLong.plan == nil)
        #expect(planTooLong.email == StandIns.statusEmail)
        let emailTooLong = AccountFacts.claudeStatus(Data("""
            {"loggedIn":true,"subscriptionType":"max","email":"\(longEmail)"}
            """.utf8))
        #expect(emailTooLong.plan == "max")
        #expect(emailTooLong.email == nil)
        let signedOut = AccountFacts.claudeStatus(Data("""
            {"loggedIn":false,"subscriptionType":"max","email":"\(StandIns.statusEmail)"}
            """.utf8))
        #expect(signedOut.plan == nil)
        #expect(signedOut.email == nil)
    }

    private func verify(_ provider: Provider, credential: UUID, rig: HelperRig, log: Log) async -> HelperRequestResult {
        let checks = AddChecks(
            api: rig.api, settings: rig.settings, timings: fastTimings, prober: FixedPrompt(answer: true),
            log: log, facts: AccountFacts(testedCodexVersions: ["0.169.0"]))
        return await checks.verify(helperRequest(
            .verify, credential: credential, params: .init(provider: provider, credentialKind: .login)))
    }
}
