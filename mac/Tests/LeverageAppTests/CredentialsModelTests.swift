import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

@MainActor
@Suite("CredentialsModel")
struct CredentialsModelTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_600)
    private let requestID = UUID(uuidString: "78787878-7878-4878-8878-787878787878")!

    private func makeModel(
        _ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([]), runtime: FakeAppRuntime = FakeAppRuntime()
    ) -> CredentialsModel {
        CredentialsModel(
            api: owner, noteRead: { seq in reads.update { $0.append(seq) } }, now: { now }, timing: .quick,
            calendar: Fixtures.utc, locale: Fixtures.usEnglish, helper: runtime.helper)
    }

    private func owner(_ list: [CredentialWithReading]? = nil, asOfSeq: Int = 11) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        let all = list ?? Fixtures.credentials().credentials
        owner.script { $0.credentials = { CredentialsList(credentials: all, asOfSeq: asOfSeq) } }
        return owner
    }

    // MARK: loading, empty, loaded

    @Test("a new list is loading and shows nothing")
    func startsLoading() {
        let model = makeModel(FakeOwnerAPI())
        #expect(model.state == .loading)
        #expect(model.rows.isEmpty)
    }

    @Test("no logins yet is loaded and empty")
    func empty() async {
        let model = makeModel(owner([]))
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.isEmpty)
    }

    @Test("each login is a row with its name, its kind and its provider, in the order given, and the position is noted")
    func loaded() async {
        let reads = Locked<[Int]>([])
        let model = makeModel(owner(asOfSeq: 17), reads: reads)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.rows.map(\.name) == ["Personal", "Team"])
        #expect(model.rows.map(\.providerName) == ["Claude", "Codex"])
        #expect(model.rows.allSatisfy { $0.kindLine == "Login" })
        #expect(reads.value == [17])
    }

    private var clock: ResetClock {
        let at = now
        return ResetClock(now: { at }, calendar: Fixtures.utc, locale: Fixtures.usEnglish)
    }

    @Test("the status dot and usage sentence show sign-out and a reported limit")
    func states() async throws {
        let later = now.addingTimeInterval(3600)
        let model = makeModel(owner([
            Fixtures.credential(Fixtures.loginID, name: "Personal"),
            Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut),
            Fixtures.account(Fixtures.geminiLoginID, name: "Work", since: now.addingTimeInterval(-60), until: later, position: 3),
            Fixtures.account(
                UUID(), name: "Old limit", since: now.addingTimeInterval(-7200), until: now.addingTimeInterval(-60), position: 4),
        ]))
        await model.load()
        try #require(model.rows.count == 4)
        #expect(!model.rows[0].isSignedOut && model.rows[0].usage == "Signed in and answering.")
        #expect(model.rows[1].isSignedOut && model.rows[1].usage == "Not signed in.")
        let time = ResetTime.text(for: later, clock: clock)
        #expect(!model.rows[2].isSignedOut)
        #expect(model.rows[2].usage == "At its limit until \(time).")
        #expect(model.rows[3].usage == "Signed in and answering.")
        for row in model.rows { #expect(BannedTerms.found(in: row.usage).isEmpty) }
    }

    @Test("a limit with no reset time says the provider did not give one")
    func limitWithNoTime() async throws {
        let model = makeModel(owner([
            Fixtures.account(Fixtures.loginID, name: "Personal", since: now.addingTimeInterval(-60), until: nil, position: 1),
            Fixtures.account(
                Fixtures.secondLoginID, name: "Team", provider: .codex, since: now.addingTimeInterval(-60), position: 2),
        ]))
        await model.load()
        try #require(model.rows.count == 2)
        #expect(!model.rows[0].isSignedOut)
        #expect(model.rows[0].usage == "At its limit. Claude did not say when it is available again.")
        #expect(model.rows[1].usage == "At its limit. Codex did not say when it is available again.")
    }

    @Test("a limit is a reported limit: a reset time with no report is not one, and a passed time ends it (HE-3)")
    func limitPredicate() async {
        let model = makeModel(owner([
            Fixtures.credential(Fixtures.loginID, name: "No report", limitedUntil: now.addingTimeInterval(600)),
            Fixtures.account(
                Fixtures.secondLoginID, name: "Passed", provider: .codex, since: now.addingTimeInterval(-600),
                until: now.addingTimeInterval(-1), position: 2),
        ]))
        await model.load()
        #expect(model.rows.map(\.usage) == ["Signed in and answering.", "Signed in and answering."])
    }

    @Test("a signed-out account at its limit says it is signed out: signing in comes first")
    func signedOutBeatsLimit() async throws {
        let model = makeModel(owner([
            Fixtures.account(
                Fixtures.loginID, name: "Personal", state: .signedOut, since: now, until: now.addingTimeInterval(60), position: 1)
        ]))
        await model.load()
        try #require(model.rows.count == 1)
        #expect(model.rows[0].isSignedOut && model.rows[0].usage == "Not signed in.")
    }

    @Test("the Credentials row shows account facts when the provider gives them")
    func showsPlanAndEmail() async throws {
        let model = makeModel(owner([
            Fixtures.account(
                Fixtures.loginID, name: "Personal", since: now, until: now.addingTimeInterval(60), position: 1,
                email: Fixtures.madeUpEmail, plan: Fixtures.madeUpPlan)
        ]))
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.accountDetails == [Fixtures.madeUpPlan, Fixtures.madeUpEmail])
    }

    @Test("an API token keeps its kind and provider")
    func tokenKind() async throws {
        let token = CredentialWithReading(
            credential: Credential(id: UUID(), kind: .apiToken, provider: .claudeApi, name: "Key", maskedLabel: MaskedLabel.forToken(""), position: 1))
        let model = makeModel(owner([token]))
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.kindLine == "API token")
        #expect(row.providerName == "Claude API")
    }

    @Test("logins and tokens have separate sections with only populated providers in registry order")
    func sections() async {
        let entries = [
            Fixtures.credential(UUID(), name: "Team", provider: .codex),
            CredentialWithReading(
                credential: Credential(id: UUID(), kind: .apiToken, provider: .openrouter, name: "Router", position: 2)),
            Fixtures.credential(UUID(), name: "Personal", provider: .claude),
            Fixtures.credential(UUID(), name: "Work", provider: .claude),
            CredentialWithReading(
                credential: Credential(id: UUID(), kind: .apiToken, provider: .openaiApi, name: "API", position: 5)),
        ]
        let model = makeModel(owner(entries))
        await model.load()
        #expect(model.sections.map(\.kind) == [.login, .apiToken])
        #expect(model.sections.map { $0.groups.map(\.provider) } == [[.claude, .codex], [.openaiApi, .openrouter]])
        #expect(model.sections.flatMap(\.groups).map { $0.rows.map(\.name) } == [
            ["Personal", "Work"], ["Team"], ["API"], ["Router"],
        ])
    }

    @Test("Rename puts duplicate name under the field and rereads after a successful correction")
    func rename() async {
        let owner = owner()
        owner.script {
            $0.renameCredential = { _, request, key in
                if request.name == "Team" {
                    return .refused(Refusal(code: .duplicateName, ruleID: nil, reason: nil),
                                    key: key.value, command: .renameCredential)
                }
                return Fixtures.plain(.renameCredential, key: key)
            }
        }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        #expect(await model.rename(Fixtures.loginID, to: "Team") == "That name is already used. Pick another.")
        #expect(Fixtures.calls(owner, .listCredentials).isEmpty)
        #expect(await model.rename(Fixtures.loginID, to: "  Work  ") == nil)
        let calls = Fixtures.calls(owner, .renameCredential)
        #expect(calls.map { $0.body?["name"]?.stringValue } == ["Team", "Work"])
        #expect(calls.allSatisfy { $0.path["id"] == Fixtures.loginID.contractString })
        #expect(Set(calls.compactMap(\.key)).count == 2)
        #expect(Fixtures.calls(owner, .listCredentials).count == 1)
    }

    @Test("Remove waits for confirmation, shows in-use on its row and forgets only after server success")
    func remove() async throws {
        let owner = owner()
        let runtime = FakeAppRuntime()
        let attempts = Locked(0)
        owner.script {
            $0.removeCredential = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 {
                    return .refused(Refusal(code: .credentialInUse, ruleID: nil, reason: nil),
                                    key: key.value, command: .removeCredential)
                }
                return Fixtures.plain(.removeCredential, key: key)
            }
        }
        let model = makeModel(owner, runtime: runtime)
        await model.load()
        owner.forgetCalls()
        model.askToRemove(Fixtures.loginID)
        #expect(model.pendingRemoval?.name == "Personal")
        model.cancelRemoval()
        #expect(model.pendingRemoval == nil)
        #expect(owner.calls.isEmpty)
        model.askToRemove(Fixtures.loginID)
        await model.remove(Fixtures.loginID)
        #expect(model.failure(for: Fixtures.loginID) == "Personal is in use by an agent or by work that is not finished.")
        #expect(model.rows.contains { $0.id == Fixtures.loginID })
        #expect(runtime.fakeHelper.messages.value.isEmpty)

        model.askToRemove(Fixtures.loginID)
        owner.script {
            $0.credentials = {
                CredentialsList(credentials: [Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex)], asOfSeq: 12)
            }
        }
        await model.remove(Fixtures.loginID)
        await model.remove(Fixtures.loginID)
        let messages = runtime.fakeHelper.messages.value
        try #require(messages.count == 1)
        if case .forget(let id) = messages[0] {
            #expect(id == Fixtures.loginID)
        } else {
            Issue.record("Remove must send forget")
        }
        #expect(Fixtures.calls(owner, .removeCredential).map { $0.path["id"] } ==
                [Fixtures.loginID.contractString, Fixtures.loginID.contractString])
        #expect(Fixtures.calls(owner, .listCredentials).count == 1)
        #expect(model.rows.map(\.id) == [Fixtures.secondLoginID])
    }

    @Test("a lost Remove answer is resolved by key if a reread finds the account gone")
    func lostRemoveAnswer() async throws {
        let owner = owner()
        let runtime = FakeAppRuntime()
        let submitted = Locked<IdempotencyKey?>(nil)
        owner.script {
            $0.removeCredential = { _, key in
                submitted.update { $0 = key }
                throw URLError(.networkConnectionLost)
            }
            $0.command = { key in
                #expect(key == submitted.value)
                return Fixtures.plain(.removeCredential, key: key)
            }
        }
        let model = makeModel(owner, runtime: runtime)
        await model.load()
        model.askToRemove(Fixtures.loginID)
        await model.remove(Fixtures.loginID)
        #expect(runtime.fakeHelper.messages.value.isEmpty)
        owner.script { $0.credentials = { CredentialsList(credentials: [], asOfSeq: 12) } }
        await model.load()
        await model.load()
        #expect(Fixtures.calls(owner, .removeCredential).count == 1)
        #expect(Fixtures.calls(owner, .getOwnerCommand).count == 1)
        let messages = runtime.fakeHelper.messages.value
        try #require(messages.count == 1)
        if case .forget(let id) = messages[0] {
            #expect(id == Fixtures.loginID)
        } else {
            Issue.record("Completed Remove must send forget")
        }
    }

    @Test("Verify and Verify all cannot overlap and duplicate a login's checks")
    func verifyDoesNotOverlap() async {
        let owner = owner()
        let modelRef = Locked<CredentialsModel?>(nil)
        owner.script {
            $0.verifyAllCredentials = { key in
                await modelRef.value?.verify(Fixtures.loginID)
                return .completed(QueuedRequests(helperRequestIDs: []), key: key.value, command: .verifyCredential)
            }
            $0.verifyCredential = { _, key in
                await modelRef.value?.verifyAll()
                return Fixtures.plain(.verifyCredential, key: key)
            }
        }
        let model = makeModel(owner)
        modelRef.update { $0 = model }
        defer { modelRef.update { $0 = nil } }
        await model.load()
        await model.verifyAll()
        #expect(Fixtures.calls(owner, .verifyCredential).isEmpty)
        owner.forgetCalls()
        await model.verify(Fixtures.loginID)
        #expect(Fixtures.calls(owner, .verifyAllCredentials).isEmpty)
        #expect(Fixtures.calls(owner, .verifyCredential).count == 1)
    }

    @Test("a later healthy usage reading clears a Refresh failure on that row")
    func refreshRecovery() async {
        let owner = owner()
        let request = requestID
        owner.script {
            $0.refreshUsage = { key in
                .completed(QueuedRequests(helperRequestIDs: [request]), key: key.value, command: .refreshUsage)
            }
            $0.helperRequest = { _, _, _ in
                Fixtures.request(request, kind: .readUsage, state: .failed, credential: Fixtures.loginID)
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.refresh()
        #expect(model.failure(for: Fixtures.loginID) == "Unavailable right now.")
        let at = now
        owner.script {
            $0.credentials = {
                let credential = Fixtures.credential(Fixtures.loginID, name: "Personal").credential
                let reading = CredentialReading(
                    credentialID: credential.id, observedAt: at.addingTimeInterval(1),
                    state: .ok, toolVersion: nil, figures: [], resets: nil)
                return CredentialsList(credentials: [CredentialWithReading(credential: credential, reading: reading)], asOfSeq: 11)
            }
        }
        await model.load()
        #expect(model.failure(for: Fixtures.loginID) == nil)
    }

    @Test("each bulk command follows its answered requests and associates progress and failure by credential ID")
    func followsBulkRequests() async {
        let owner = owner()
        let request = requestID
        let second = UUID()
        let observed = Locked<[String?]>([])
        let modelRef = Locked<CredentialsModel?>(nil)
        let kind = Locked(HelperRequestKind.readUsage)
        owner.script {
            $0.refreshUsage = { key in
                .completed(QueuedRequests(helperRequestIDs: [second, request]), key: key.value, command: .refreshUsage)
            }
            $0.verifyAllCredentials = { key in
                kind.update { $0 = .verify }
                return .completed(QueuedRequests(helperRequestIDs: [request, second]), key: key.value, command: .verifyCredential)
            }
            $0.helperRequest = { id, _, changedAfter in
                let credential = id == request ? Fixtures.secondLoginID : Fixtures.loginID
                let requestKind = kind.value
                if changedAfter == nil {
                    return Fixtures.request(id, kind: requestKind, state: .pickedUp, credential: credential)
                }
                let line = await MainActor.run { modelRef.value?.progress(for: credential) }
                observed.update { $0.append(line) }
                if id == request {
                    let check = requestKind == .verify ? HelperCheck.signedIn : .readingTaken
                    return Fixtures.request(
                        id, kind: requestKind, state: .failed,
                        result: Fixtures.finished(.failed, failing: [
                            HelperCheckResult(check: check, passed: false, failure: .notSignedIn),
                        ]), credential: credential)
                }
                return Fixtures.request(id, kind: requestKind, state: .finished, result: Fixtures.finished(), credential: credential)
            }
        }
        let model = makeModel(owner)
        modelRef.update { $0 = model }
        defer { modelRef.update { $0 = nil } }
        await model.load()
        owner.forgetCalls()
        await model.refresh()
        #expect(Fixtures.calls(owner, .refreshUsage).count == 1)
        #expect(observed.value == ["Reading usage…", "Reading usage…"])
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 4)
        #expect(Fixtures.calls(owner, .listCredentials).count == 2)
        #expect(model.failure(for: Fixtures.secondLoginID) == "Unavailable right now.")
        #expect(model.failure(for: Fixtures.loginID) == nil)

        owner.forgetCalls()
        observed.update { $0 = [] }
        await model.verifyAll()
        #expect(Fixtures.calls(owner, .verifyAllCredentials).count == 1)
        #expect(observed.value == ["Checking…", "Checking…"])
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 4)
        #expect(Fixtures.calls(owner, .listCredentials).count == 2)
        #expect(model.failure(for: Fixtures.secondLoginID) == "Codex is not signed in.")
        #expect(model.failure(for: Fixtures.loginID) == nil)
        #expect(model.progress(for: Fixtures.secondLoginID) == nil)
    }

    @Test("the visible tab rereads without an event and cancellation ends the loop")
    func pollsWhileVisible() async {
        let owner = owner()
        let model = makeModel(owner)
        let task = Task { await model.keepCurrent(every: .milliseconds(10)) }
        #expect(await ShellFixtures.eventually { model.rows.count == 2 })
        owner.script { $0.credentials = { CredentialsList(credentials: [], asOfSeq: 11) } }
        #expect(await ShellFixtures.eventually { model.rows.isEmpty })
        task.cancel()
        await task.value
        #expect(Fixtures.calls(owner, .listCredentials).count >= 2)
    }

    // MARK: failures

    @Test("a read that cannot reach the server shows one plain line and keeps the rows shown before")
    func cannotReach() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        owner.script { $0.credentials = { throw URLError(.notConnectedToInternet) } }
        await model.load()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.rows.count == 2)
    }

    @Test("a 401 shows the signed-out state")
    func signedOut() async {
        let owner = FakeOwnerAPI()
        owner.script { $0.credentials = { throw ShellFixtures.unauthenticated() } }
        let model = makeModel(owner)
        await model.load()
        #expect(model.state == .signedOut)
    }

    // MARK: Verify

    @Test("Verify sends verify_credential for that login, follows the request and reads again")
    func verify() async {
        let owner = owner()
        let request = requestID
        owner.script {
            $0.verifyCredential = { _, key in Fixtures.plain(.verifyCredential, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                Fixtures.request(request, kind: .verify, state: .finished, result: Fixtures.finished(), credential: Fixtures.loginID)
            }
        }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.verify(Fixtures.loginID)
        let sent = Fixtures.calls(owner, .verifyCredential)
        #expect(sent.count == 1 && sent.first?.path["id"] == Fixtures.loginID.contractString)
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 1)
        #expect(Fixtures.calls(owner, .listCredentials).count == 1)
        #expect(!model.isVerifying(Fixtures.loginID))
        #expect(model.failure(for: Fixtures.loginID) == nil)
    }

    @Test("a verify that fails says which check, in one line on that row")
    func verifyFails() async {
        let owner = owner()
        let request = requestID
        owner.script {
            $0.verifyCredential = { _, key in Fixtures.plain(.verifyCredential, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                Fixtures.request(
                    request, kind: .verify, state: .failed,
                    progress: [Fixtures.progress(.signedIn, .failed, failure: .notSignedIn)],
                    result: Fixtures.finished(.failed, failing: [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)]),
                    credential: Fixtures.loginID)
            }
        }
        let model = makeModel(owner)
        await model.load()
        await model.verify(Fixtures.loginID)
        #expect(model.failure(for: Fixtures.loginID) == "Claude Code is not signed in.")
        #expect(model.failure(for: Fixtures.secondLoginID) == nil)
    }

    @Test("Verify sent again after the network failed uses the same key; after an answer a new one")
    func verifyKeys() async {
        let owner = owner()
        let request = requestID
        let attempts = Locked(0)
        owner.script {
            $0.verifyCredential = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return Fixtures.plain(.verifyCredential, key: key, helperRequest: request)
            }
            $0.helperRequest = { _, _, _ in Fixtures.request(request, kind: .verify, state: .finished, result: Fixtures.finished()) }
        }
        let model = makeModel(owner)
        await model.load()
        await model.verify(Fixtures.loginID)
        #expect(model.failure(for: Fixtures.loginID) == ShellCopy.cannotReach.text)
        await model.verify(Fixtures.loginID)
        await model.verify(Fixtures.loginID)
        let keys = Fixtures.calls(owner, .verifyCredential).map(\.key)
        #expect(keys.count == 3 && keys[0] == keys[1] && keys[1] != keys[2])
    }

    @Test("a refused Verify shows the sentence for its code")
    func verifyRefused() async {
        let owner = owner()
        let refusal = Refusal(code: .forbidden, ruleID: nil, reason: nil)
        owner.script { $0.verifyCredential = { _, key in .refused(refusal, key: key.value, command: .verifyCredential) } }
        let model = makeModel(owner)
        await model.load()
        await model.verify(Fixtures.loginID)
        #expect(model.failure(for: Fixtures.loginID) == ShellCopy.refusalForbidden.text)
    }

    @Test("Verify for a login that is not on the list sends nothing")
    func verifyUnknown() async {
        let owner = owner()
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.verify(UUID())
        #expect(owner.calls.isEmpty)
    }

    // MARK: Sign in again (HM-47)

    @Test("only a signed-out login has Sign in again")
    func signInAgainOffered() async {
        let model = makeModel(owner([
            Fixtures.credential(Fixtures.loginID, name: "Personal"),
            Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut),
            Fixtures.account(
                Fixtures.geminiLoginID, name: "Work", kind: .apiToken, state: .signedOut, position: 3),
            Fixtures.account(UUID(), name: "Limited", since: now, until: now.addingTimeInterval(60), position: 4),
        ]))
        await model.load()
        #expect(model.rows.map(\.canSignInAgain) == [false, true, false, false])
    }

    private func signInOwner(
        _ finished: @escaping @Sendable () -> HelperRequestStatus
    ) -> FakeOwnerAPI {
        let owner = owner([
            Fixtures.credential(Fixtures.loginID, name: "Personal"),
            Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut),
        ])
        let request = requestID
        owner.script {
            $0.signInAgain = { _, key in Fixtures.plain(.signInAgain, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in finished() }
        }
        return owner
    }

    @Test("Sign in again sends sign_in_again for that login, follows the request to its end and reads again")
    func signInAgain() async {
        let request = requestID
        let owner = signInOwner {
            Fixtures.request(request, kind: .openSignIn, state: .finished, result: Fixtures.finished(), credential: Fixtures.secondLoginID)
        }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.signInAgain(Fixtures.secondLoginID)
        let sent = Fixtures.calls(owner, .signInAgain)
        #expect(sent.count == 1 && sent.first?.path["id"] == Fixtures.secondLoginID.contractString)
        #expect(sent.first?.key != nil)
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 1)
        #expect(Fixtures.calls(owner, .listCredentials).count == 1)
        #expect(!model.isSigningIn(Fixtures.secondLoginID))
        #expect(model.failure(for: Fixtures.secondLoginID) == nil)
    }

    @Test("while the request runs the row says it waits for the owner to sign in in the window that opened")
    func signInAgainWaits() async {
        let request = requestID
        let seen = Locked<[Bool]>([])
        let owner = owner([Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut)])
        let box = Locked<CredentialsModel?>(nil)
        owner.script {
            $0.signInAgain = { _, key in Fixtures.plain(.signInAgain, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                let waiting = await MainActor.run { box.value?.isSigningIn(Fixtures.secondLoginID) == true }
                seen.update { $0.append(waiting) }
                return Fixtures.request(request, kind: .openSignIn, state: .finished, result: Fixtures.finished())
            }
        }
        let model = makeModel(owner)
        box.update { $0 = model }
        await model.load()
        await model.signInAgain(Fixtures.secondLoginID)
        #expect(seen.value == [true])
        #expect(!model.isSigningIn(Fixtures.secondLoginID))
        #expect(CredentialsCopy.waitingSignIn.text == "Waiting for you to sign in in the window that opened")
    }

    // Review: Antigravity has no sign-in command, so no window opens.
    @Test("while Sign in again waits for a Gemini login the row says to sign in to Antigravity, not to a window")
    func signInAgainWaitsGemini() async {
        let request = requestID
        let lines = Locked<[String?]>([])
        let owner = owner([Fixtures.credential(Fixtures.geminiLoginID, name: "Work", provider: .gemini, state: .signedOut)])
        let box = Locked<CredentialsModel?>(nil)
        owner.script {
            $0.signInAgain = { _, key in Fixtures.plain(.signInAgain, key: key, helperRequest: request) }
            $0.helperRequest = { _, _, _ in
                let line = await MainActor.run { box.value?.signInWaitingLine(Fixtures.geminiLoginID) }
                lines.update { $0.append(line) }
                return Fixtures.request(request, kind: .openSignIn, state: .finished, result: Fixtures.finished())
            }
        }
        let model = makeModel(owner)
        box.update { $0 = model }
        await model.load()
        await model.signInAgain(Fixtures.geminiLoginID)
        #expect(lines.value == [CredentialsCopy.waitingGemini.text])
        #expect(model.signInWaitingLine(Fixtures.geminiLoginID) == nil)
    }

    @Test("a sign-in that fails says which tool and what it did not do, in one line on that row")
    func signInAgainFails() async {
        let request = requestID
        let owner = signInOwner {
            Fixtures.request(
                request, kind: .openSignIn, state: .failed,
                progress: [Fixtures.progress(.signedIn, .failed, failure: .notSignedIn)],
                result: Fixtures.finished(.failed, failing: [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)]),
                credential: Fixtures.secondLoginID)
        }
        let model = makeModel(owner)
        await model.load()
        await model.signInAgain(Fixtures.secondLoginID)
        #expect(model.failure(for: Fixtures.secondLoginID) == "Codex is not signed in.")
        #expect(model.failure(for: Fixtures.loginID) == nil)
    }

    @Test("Sign in again sends nothing for a login that is not signed out, or not on the list")
    func signInAgainOnlyWhereItMakesSense() async {
        let owner = signInOwner { Fixtures.request(UUID(), state: .finished, result: Fixtures.finished()) }
        let model = makeModel(owner)
        await model.load()
        owner.forgetCalls()
        await model.signInAgain(Fixtures.loginID)
        await model.signInAgain(UUID())
        #expect(owner.calls.isEmpty)
    }

    @Test("Sign in again sent again after the network failed uses the same key; after an answer a new one")
    func signInAgainKeys() async {
        let owner = owner([Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut)])
        let request = requestID
        let attempts = Locked(0)
        owner.script {
            $0.signInAgain = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                return Fixtures.plain(.signInAgain, key: key, helperRequest: request)
            }
            $0.helperRequest = { _, _, _ in Fixtures.request(request, kind: .openSignIn, state: .finished, result: Fixtures.finished()) }
        }
        let model = makeModel(owner)
        await model.load()
        await model.signInAgain(Fixtures.secondLoginID)
        #expect(model.failure(for: Fixtures.secondLoginID) == ShellCopy.cannotReach.text)
        await model.signInAgain(Fixtures.secondLoginID)
        await model.signInAgain(Fixtures.secondLoginID)
        let keys = Fixtures.calls(owner, .signInAgain).map(\.key)
        #expect(keys.count == 3 && keys[0] == keys[1] && keys[1] != keys[2])
    }

    @Test("a refused Sign in again does not keep its key")
    func signInAgainRefusedKeyDropped() async {
        let owner = owner([Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut)])
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.signInAgain = { _, key in .refused(refusal, key: key.value, command: .signInAgain) } }
        let model = makeModel(owner)
        await model.load()
        await model.signInAgain(Fixtures.secondLoginID)
        await model.signInAgain(Fixtures.secondLoginID)
        let keys = Fixtures.calls(owner, .signInAgain).map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
    }

    @Test("a refused Sign in again shows the sentence for its code")
    func signInAgainRefused() async {
        let owner = owner([Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut)])
        let refusal = Refusal(code: .invalidState, ruleID: nil, reason: nil)
        owner.script { $0.signInAgain = { _, key in .refused(refusal, key: key.value, command: .signInAgain) } }
        let model = makeModel(owner)
        await model.load()
        await model.signInAgain(Fixtures.secondLoginID)
        #expect(model.failure(for: Fixtures.secondLoginID) == ShellCopy.refusalInvalidState.text)
    }

    // MARK: staying current

    @Test("an event from the tail reads the list again")
    func readsAgainOnEvents() async {
        let owner = owner()
        let batches = Locked<[EventsPage]>([])
        owner.script {
            $0.events = { _, _, _ in
                while true {
                    if let page = batches.update({ $0.isEmpty ? nil : $0.removeFirst() }) { return page }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let feed = EventFeed(owner: owner, waitSeconds: 25, retryDelay: .milliseconds(5))
        let model = CredentialsModel(
            api: owner, noteRead: { feed.noteRead(asOfSeq: $0) }, now: { now }, timing: .quick,
            helper: FakeAppRuntime().helper)
        model.attach(to: feed)
        await model.load()
        #expect(model.rows.count == 2)
        owner.script {
            $0.credentials = { CredentialsList(credentials: [Fixtures.credential(Fixtures.loginID, name: "Only")], asOfSeq: 14) }
        }
        batches.update { $0.append(EventsPage(events: [ShellFixtures.event(seq: 14)], nextAfterSeq: 14)) }
        #expect(await ShellFixtures.eventually { model.rows.map(\.name) == ["Only"] })
        model.detach()
        feed.stop()
    }

    // MARK: the screen

    @Test("the Credentials screen draws loaded, empty and failed, light and dark")
    func renders() async {
        let loaded = makeModel(owner([
            Fixtures.credential(Fixtures.loginID, name: "Personal"),
            Fixtures.credential(Fixtures.secondLoginID, name: "Team", provider: .codex, state: .signedOut),
            Fixtures.account(Fixtures.geminiLoginID, name: "Work", since: now, until: now.addingTimeInterval(600), position: 3),
        ]))
        await loaded.load()
        #expect(Fixtures.draws(CredentialsContent(model: loaded, add: {})))
        #expect(Fixtures.draws(CredentialsContent(model: loaded, add: {}).environment(\.colorScheme, .dark)))
        let empty = makeModel(owner([]))
        await empty.load()
        #expect(Fixtures.draws(CredentialsContent(model: empty, add: {})))
        let failing = FakeOwnerAPI()
        failing.script { $0.credentials = { throw URLError(.timedOut) } }
        let failed = makeModel(failing)
        await failed.load()
        #expect(Fixtures.draws(CredentialsContent(model: failed, add: {})))
    }

    @Test("the screens are built with no arguments and draw inside the shell's context")
    func zeroArgumentScreens() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let model = rig.makeModel()
        await model.start()
        let context = model.screens!
        #expect(Fixtures.draws(RosterView().environment(context)))
        #expect(Fixtures.draws(CredentialsView().environment(context)))
    }
}
