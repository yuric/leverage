import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@Suite("Credential test support")
struct CredentialTestSupportTests {
    private enum SendFailure: Error { case unavailable }

    @Test("the helper fake records sent messages in order, including failed sends")
    func helperMessages() async throws {
        let runtime = FakeAppRuntime()
        let credentialID = UUID()
        let token = "LVRG-TOKEN-000000000001"
        try await runtime.helper.send(.token(credentialID: credentialID, token: token))
        runtime.fakeHelper.sendFailure.value = SendFailure.unavailable
        await #expect(throws: SendFailure.unavailable) {
            try await runtime.helper.send(.forget(credentialID: credentialID))
        }

        let messages = runtime.fakeHelper.messages.value
        try #require(messages.count == 2)
        guard case .token(let recordedID, let recordedToken) = messages[0],
              case .forget(let forgottenID) = messages[1] else {
            Issue.record("expected a token message followed by a forget message")
            return
        }
        #expect(recordedID == credentialID)
        #expect(recordedToken == token)
        #expect(forgottenID == credentialID)
    }

    @Test("the unavailable runtime refuses messages when the helper is not running")
    func unavailableHelper() async {
        let runtime = UnavailableRuntime()
        let credentialID = UUID()
        await #expect(throws: HelperSendError.notRunning) {
            try await runtime.helper.send(.forget(credentialID: credentialID))
        }
    }

    @Test("the credential APIs record new commands with their ids, keys and bodies")
    func credentialAPIs() async throws {
        let owner = FakeOwnerAPI()
        let helper = FakeHelperAPI()
        let id = UUID()
        let key = IdempotencyKey()
        let rename = RenameCredentialRequest(name: "Made-up login")
        let reorder = ReorderCredentialsRequest(order: [id])
        let reading = CredentialReading(
            credentialID: id, observedAt: Date(timeIntervalSince1970: 1), state: .ok,
            toolVersion: nil, figures: [], resets: nil)
        let path = ["id": id.uuidString.lowercased()]
        await #expect(throws: FakeAPIError.notScripted(.renameCredential)) {
            _ = try await owner.renameCredential(credentialID: id, rename, key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.removeCredential)) {
            _ = try await owner.removeCredential(credentialID: id, key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.refreshUsage)) {
            _ = try await owner.refreshUsage(key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.verifyAllCredentials)) {
            _ = try await owner.verifyAllCredentials(key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.reorderCredentials)) {
            _ = try await owner.reorderCredentials(reorder, key: key)
        }
        await #expect(throws: FakeAPIError.notScripted(.reportReading)) {
            _ = try await helper.reportReading(credentialID: id, reading, key: key)
        }
        #expect(owner.calls == [
            FakeCall(.renameCredential, path: path, key: key, body: FakeCall.json(rename)),
            FakeCall(.removeCredential, path: path, key: key),
            FakeCall(.refreshUsage, key: key),
            FakeCall(.verifyAllCredentials, key: key),
            FakeCall(.reorderCredentials, key: key, body: FakeCall.json(reorder)),
        ])
        #expect(helper.calls == [FakeCall(.reportReading, path: path, key: key, body: FakeCall.json(reading))])
    }

    @Test("the tool scenario writes RD-8 usage directives with the stand-in's keys")
    func toolScenario() throws {
        let folder = try TemporaryFolder()
        let tools = try StandIns.copy(into: folder.url)
        let claude = folder.path("claude account")
        let codex = folder.path("codex account")
        let otherCodexHome = folder.path("other codex home")
        try tools.write(scenario: StandInScenario(usage: [
            .init(tool: "claude", account: claude, reply: "claude/usage-two-windows.json",
                  settings: "claude/usage-settings.json", staleSettings: true, version: "2.0.0"),
            .init(tool: "codex", account: codex, reply: "codex/usage-both-windows.json", codexHome: otherCodexHome),
            .init(tool: "codex", neverAnswers: true),
        ]))

        let data = try Data(contentsOf: tools.state.appendingPathComponent("scenario.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = try #require(object["usage"] as? [NSDictionary])
        let expected: [NSDictionary] = [
            ["tool": "claude", "account": claude.path, "reply": "claude/usage-two-windows.json",
             "settings": "claude/usage-settings.json", "stale_settings": true, "version": "2.0.0"],
            ["tool": "codex", "account": codex.path, "reply": "codex/usage-both-windows.json",
             "codex_home": otherCodexHome.path],
            ["tool": "codex", "never_answers": true],
        ]
        #expect(usage == expected)
    }

    @Test("the provider API scenario maps each fake token marker to its directive")
    func providerAPIScenario() throws {
        let folder = try TemporaryFolder()
        let tools = try StandIns.copy(into: folder.url)
        let answer = "LVRG-TOKEN-000000000001"
        let timeout = "LVRG-TOKEN-000000000002"
        let reply = "openrouter/usage-ok.json"
        let url = try tools.writeProviderAPIScenario(tokens: [answer: .reply(reply), timeout: .neverAnswers])
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSDictionary])
        let expected: NSDictionary = [answer: ["reply": reply], timeout: ["never_answers": true]]
        #expect(object == ["tokens": expected])
    }
}
