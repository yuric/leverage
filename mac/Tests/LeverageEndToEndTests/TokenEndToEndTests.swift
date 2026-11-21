import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LeverageKit
import LeverageTestSupport
import Testing

@Suite("API tokens end to end", .enabled(if: credentialsEnabled))
struct TokenEndToEndTests {
    @Test("API tokens stay local through Add, Retry, Refresh, Verify and Remove")
    func tokens() async throws {
        let router = Sample(provider: .openrouter, number: 1, reply: "usage-ok.json")
        let grok = Sample(provider: .grokApi, number: 2, reply: "usage-ok.json")
        let rejected = Sample(provider: .openrouter, number: 3, reply: "usage-signed-out.json")
        let replacement = Sample(provider: .openrouter, number: 4, reply: "usage-ok.json")
        let samples = [router, grok, rejected, replacement]
        var directives = Dictionary(uniqueKeysWithValues: samples.map { ($0.marker, $0.directive) })
        let world = try await CredentialsHarness.start(name: "tokens", tokens: directives)

        try await withCleanup {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TokenResponseAudit.self]
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let owner = OwnerClient(baseURL: world.owner.transport.baseURL,
                                    sessionToken: world.owner.transport.token, session: session)
            let follower = try await EventFollower.fromNow(owner: owner)
            let api = world.providerAPI
            let helper = world.helper
            let deadline = CredentialsHarness.deadline
            try (samples.map(\.marker).joined(separator: "\n") + "\n").write(
                to: world.folder.url.appendingPathComponent("token-markers.txt"), atomically: true, encoding: .utf8)

            let claude = try await owner.addLogin(.claude, name: "Claude", deadline: deadline)
            let builder = try await owner.connect("Builder", role: .builder, login: claude)
            try await eventually("the builder’s run started", deadline: deadline) {
                try await owner.seats().seats.contains { $0.id == builder && $0.runState == .running }
            }

            let routerID = UUID()
            try await add(router, id: routerID, name: "OpenRouter", helper: helper, owner: owner)
            let spending = try await firstReading(routerID, owner: owner, follower: follower)
            let expected = try router.expectation(in: world.tools)
            #expect(spending.state == expected.state && spending.figures == expected.figures)
            #expect(spending.resets == nil)

            let grokID = UUID()
            try await add(grok, id: grokID, name: "Grok API", helper: helper, owner: owner)
            let grokReading = try await firstReading(grokID, owner: owner, follower: follower)
            #expect(grokReading.state == .ok && grokReading.figures.isEmpty && grokReading.resets == nil)

            let retryID = UUID()
            try await add(rejected, id: retryID, name: "Retry", helper: helper, owner: owner, failure: .rejected)
            let failedRows = try await owner.credentials().credentials
            #expect(failedRows.allSatisfy { $0.credential.id != retryID })
            let failedEvents = try await owner.events(afterSeq: 0, limit: 500, wait: nil).events
            #expect(!failedEvents.contains { $0.type == .credentialAdded && $0.subjectID == retryID })
            try await add(replacement, id: retryID, name: "Retry", helper: helper, owner: owner)
            let retried = try await firstReading(retryID, owner: owner, follower: follower)
            #expect(retried.state == .ok && retried.figures == spending.figures)

            let codex = try await owner.addLogin(.codex, name: "Codex", deadline: deadline)
            let ordered = try await owner.credentials().credentials
            #expect(ordered.map(\.credential.id) == [claude, codex, routerID, grokID, retryID])
            #expect(ordered.map(\.credential.position) == Array(1...5))
            #expect(ordered.map(\.credential.maskedLabel) == [nil, nil, mask, mask, mask])
            #expect(ordered.filter { $0.credential.kind == .apiToken }.allSatisfy {
                $0.credential.accountEmail == nil && $0.credential.plan == nil
            })

            let attemptedSeat = ConnectSeatRequest(name: "Token builder", role: .builder, credentialID: routerID)
            do {
                _ = try await owner.connectSeat(attemptedSeat, key: IdempotencyKey())
                Issue.record("Connect accepted an API token")
            } catch let error as TransportError {
                #expect(error.code == .invalid && error.status == 422)
            }
            let seats = try await owner.seats().seats
            #expect(seats.map(\.id) == [builder])

            let renameKey = IdempotencyKey()
            _ = try await owner.renameCredential(credentialID: grokID, .init(name: "Renamed Grok API"),
                                                 key: renameKey).completedResult()
            _ = try await follower.wait(for: "token rename", deadline: deadline) {
                $0.type == .credentialRenamed && $0.subjectID == grokID && $0.commandID == renameKey.value
            }
            let renamed = try await row(grokID, owner: owner).credential
            #expect(renamed.name == "Renamed Grok API" && renamed.maskedLabel == mask)

            directives[grok.marker] = .neverAnswers
            try api.update(tokens: directives)
            let refreshed = try await refresh(owner: owner)
            let hung = try #require(refreshed.first { $0.credentialID == grokID })
            #expect(hung.state == .failed)
            #expect(hung.result?.checks == [HelperCheckResult(check: .readingTaken, passed: false, failure: .timedOut)])
            let unavailable = try await row(grokID, owner: owner).reading
            #expect(unavailable?.state == .unavailable && unavailable?.figures.isEmpty == true)
            #expect(unavailable?.observedAt ?? .distantPast > grokReading.observedAt)
            let refreshedSpending = try await row(routerID, owner: owner).reading
            #expect(refreshedSpending?.state == .ok && refreshedSpending?.figures == spending.figures)
            #expect(refreshedSpending?.observedAt ?? .distantPast > spending.observedAt)

            let beforeRefusal = try await owner.credentials().credentials.map(\.credential)
            let refusedKey = IdempotencyKey()
            let refused = try await owner.removeCredential(credentialID: claude, key: refusedKey)
            #expect(refused.outcome == .refused && refused.refusal?.code == .credentialInUse)
            let afterRefusal = try await owner.credentials().credentials.map(\.credential)
            #expect(afterRefusal == beforeRefusal)

            let beforeVerify = try api.calls().count
            try await helper.send(.forget(credentialID: grokID))
            let verify = try await owner.followed(
                "Verify the forgotten token", owner.verifyCredential(credentialID: grokID, key: IdempotencyKey()),
                expected: .failed, deadline: deadline)
            #expect(verify.result?.checks == [HelperCheckResult(check: .tokenWorks, passed: false, failure: .notSignedIn)])
            let signedOut = try await follower.wait(for: "forgotten token reported signed out", deadline: deadline) {
                $0.type == .credentialSignedOut && $0.subjectID == grokID
            }
            #expect(signedOut.payload["seat_id"] == .null)
            let forgotten = try await row(grokID, owner: owner)
            #expect(forgotten.credential.state == .signedOut && forgotten.reading == unavailable)
            #expect(try api.calls().count == beforeVerify)

            let removeKey = IdempotencyKey()
            _ = try await owner.removeCredential(credentialID: routerID, key: removeKey).completedResult()
            _ = try await follower.wait(for: "OpenRouter token removed", deadline: deadline) {
                $0.type == .credentialRemoved && $0.subjectID == routerID && $0.commandID == removeKey.value
            }
            try await helper.send(.forget(credentialID: routerID))
            let remaining = try await refresh(owner: owner)
            #expect(remaining.allSatisfy { $0.credentialID != routerID && $0.credentialID != grokID })
            let afterRemove = try await owner.credentials().credentials
            #expect(afterRemove.map(\.credential.id) == [claude, codex, grokID, retryID])
            let calls = try api.calls()
            assertCalls(calls, for: router, count: 3)
            assertCalls(calls, for: grok, count: 3)
            assertCalls(calls, for: rejected, count: 1)
            assertCalls(calls, for: replacement, count: 4)
            let callsCount = calls.count
            #expect(callsCount == 11, "all provider calls were accounted for")

            try await owner.stopAndWait(seat: builder)
            let events = try await owner.events(afterSeq: 0, limit: 500, wait: nil).events
            #expect(!events.contains { $0.commandID == refusedKey.value })
            #expect(events.filter { $0.type == .credentialAdded && $0.subjectID == retryID }.count == 1)
        } cleanup: {
            await world.stop()
        }
    }

    private let mask = "••••••••"

    private func add(
        _ sample: Sample, id: UUID, name: String, helper: RunningHelper, owner: OwnerClient,
        failure: HelperCheckFailure? = nil
    ) async throws {
        try await helper.send(.token(credentialID: id, token: sample.marker))
        let request = AddCredentialRequest(credentialID: id, kind: .apiToken, provider: sample.provider,
                                           name: name, maskedLabel: MaskedLabel.forToken(sample.marker))
        let add = try await owner.addCredential(request, key: IdempotencyKey()).completedResult()
        let queued = try #require(add)
        #expect(queued.credentialID == id)
        let check = try await finishedRequest(queued.helperRequestID, owner: owner,
                                              deadline: CredentialsHarness.deadline)
        #expect(check.credentialID == id)
        let expected = HelperCheckResult(check: .tokenWorks, passed: failure == nil, failure: failure)
        try #require(check.result?.checks == [expected])
        try #require(check.state == (failure == nil ? .finished : .failed))
    }

    private func firstReading(_ id: UUID, owner: OwnerClient, follower: EventFollower) async throws -> CredentialReading {
        let deadline = CredentialsHarness.deadline
        _ = try await follower.wait(for: "token added", deadline: deadline) {
            $0.type == .credentialAdded && $0.subjectID == id
        }
        var reading: CredentialReading?
        try await eventually("the token's first reading", deadline: deadline) {
            reading = try await row(id, owner: owner).reading
            return reading != nil
        }
        return try #require(reading)
    }

    private func refresh(owner: OwnerClient) async throws -> [HelperRequest] {
        let outcome = try await owner.refreshUsage(key: IdempotencyKey()).completedResult()
        let queued = try #require(outcome)
        var requests: [HelperRequest] = []
        for id in queued.helperRequestIDs {
            let request = try await finishedRequest(id, owner: owner, deadline: CredentialsHarness.deadline)
            #expect(request.kind == .readUsage)
            requests.append(request)
        }
        return requests
    }

    private func row(_ id: UUID, owner: OwnerClient) async throws -> CredentialWithReading {
        let rows = try await owner.credentials().credentials
        return try #require(rows.first { $0.credential.id == id })
    }

    private func assertCalls(_ calls: [RunningProviderAPI.Call], for sample: Sample, count: Int) {
        let matching = calls.filter { $0.headers["authorization"] == "Bearer " + sample.marker }
        let actualCount = matching.count
        #expect(actualCount == count, "one request per check or read")
        let path = sample.provider == .openrouter ? "/api/v1/key" : "/v1/api-key"
        let allAreReads = matching.allSatisfy {
            $0.method == "GET" && $0.path == path && $0.headers.count == 1
        }
        #expect(allAreReads, "every request was the documented GET for that token")
    }

    private struct Sample {
        let provider: Provider
        let number: Int
        let reply: String

        var marker: String { "LVRG-TOKEN-" + String(format: "%012d", number) }
        var path: String { "\(provider.rawValue)/\(reply)" }
        var directive: StandInScenario.TokenDirective { .reply(path) }

        func expectation(in tools: StandInTools) throws -> Expectation {
            let fixture = try Data(contentsOf: tools.replies.appendingPathComponent(path))
            return try JSONDecoder().decode(Fixture.self, from: fixture).meta.expect
        }

        private struct Fixture: Decodable {
            let meta: Metadata
            struct Metadata: Decodable { let expect: Expectation }
        }

        struct Expectation: Decodable {
            let state: ReadingState
            let figures: [Figure]
        }
    }
}

/// Observes the actual response before OwnerClient decodes it. An unknown
/// JSON field would otherwise be dropped even if it carried a token.
private final class TokenResponseAudit: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var forwarding: URLSessionDataTask?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self, let client = self.client else { return }
            if let error {
                client.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let data, let response else {
                client.urlProtocol(self, didFailWithError: LeverageClientError.notHTTP)
                return
            }
            if String(decoding: data, as: UTF8.self).contains("LVRG-TOKEN-") {
                client.urlProtocol(self, didFailWithError: EndToEndFailure("the owner response carried a token marker"))
                return
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        }
        lock.withLock {
            if stopped { task.cancel() } else { forwarding = task }
        }
        task.resume()
    }

    override func stopLoading() {
        let task = lock.withLock {
            stopped = true
            defer { forwarding = nil }
            return forwarding
        }
        task?.cancel()
    }
}
