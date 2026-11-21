import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Token checks", .serialized, .timeLimit(.minutes(Patience.minutes(1))))
struct TokenChecksTests {
    private let token = "LVRG-TOKEN-000000000702"
    private let provider = Provider.grokApi
    private let host = "api.x.ai"

    @Test("token_works classifies provider responses and saves only a passing add", arguments: [
        (200, "{}", nil as HelperCheckFailure?),
        (200, "{\"api_key_blocked\":true}", .rejected),
        (200, "{\"api_key_disabled\":true}", .rejected),
        (200, "{\"team_blocked\":true}", .rejected),
        (401, "{}", .rejected), (403, "{}", .rejected), (503, "{}", .unreachable),
    ])
    func response(status: Int, body: String, failure: HelperCheckFailure?) async throws {
        try await exercise(answer: .init(status: status, json: body), failure: failure)
    }

    @Test("a failed connection and a timeout are distinct")
    func transportFailures() async throws {
        try await exercise(answer: .failure(.cannotConnectToHost), failure: .unreachable)
        try await exercise(answer: .failure(.timedOut), failure: .timedOut)
    }

    private func exercise(answer: StubURLProtocol.Answer, failure: HelperCheckFailure?) async throws {
        let rig = try HelperRig()
        let credential = UUID()
        let pending = PendingTokens()
        let vault = MemoryTokenVault()
        let alreadyStored = Locked(false)
        let stub = StubURLProtocol.session(host: host) { _, _ in
            alreadyStored.value = (try? vault.read(credentialID: credential)) != nil
            return answer
        }
        defer { stub.invalidateAndCancel() }
        let transport = try ProviderHTTP(
            executableURL: URL(fileURLWithPath: "/test/LeverageHelper"), environment: [:],
            protocolClasses: [StubURLProtocol.self])
        let request = helperRequest(.runAddChecks, credential: credential, params: .init(provider: provider, credentialKind: .apiToken))
        await pending.insert(token, credentialID: credential)
        var check = CheckRun(request: request, api: rig.api, log: quietLog)
        let result = await TokenChecks(pending: pending, vault: vault, http: transport, timeout: Patience.scaled(.seconds(30)))
            .run(provider, credentialID: credential, adding: true, check: &check)

        #expect(result.outcome == (failure == nil ? .finished : .failed))
        #expect(result.checks == [HelperCheckResult(check: .tokenWorks, passed: failure == nil, failure: failure)])
        #expect(rig.progress(of: request.id).map(\.state) == [.waiting, .running, failure == nil ? .passed : .failed])
        #expect(!alreadyStored.value)
        let saved = try vault.read(credentialID: credential)
        #expect(saved == nil ? failure != nil : failure == nil)
        #expect(StubURLProtocol.requests(host: host).count == 1)
        #expect(!rig.everythingSent().contains("LVRG-TOKEN-"))
    }

    @Test("a missing pasted token times out, and Verify with no saved token is not signed in")
    func missingToken() async throws {
        let rig = try HelperRig()
        let vault = MemoryTokenVault()
        let now = ContinuousClock.now
        let clock = Locked(now)
        let pending = PendingTokens(now: { clock.value }, sleep: { clock.value = $0 })
        let stub = StubURLProtocol.session(host: host, answer: .init(status: 200, json: "{}"))
        defer { stub.invalidateAndCancel() }
        let transport = try ProviderHTTP(
            executableURL: URL(fileURLWithPath: "/test/LeverageHelper"), environment: [:],
            protocolClasses: [StubURLProtocol.self])
        let tokens = TokenChecks(pending: pending, vault: vault, http: transport, timeout: .seconds(2))
        let credential = UUID()
        for (adding, failure) in [(true, HelperCheckFailure.timedOut), (false, .notSignedIn)] {
            let request = helperRequest(adding ? .runAddChecks : .verify, credential: credential,
                                        params: .init(provider: provider, credentialKind: .apiToken))
            var check = CheckRun(request: request, api: rig.api, log: quietLog)
            let result = await tokens.run(provider, credentialID: credential, adding: adding, check: &check)
            #expect(result.checks == [HelperCheckResult(check: .tokenWorks, passed: false, failure: failure)])
        }
        #expect(StubURLProtocol.requests(host: host).isEmpty)
    }
}
