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

    private func makeModel(_ owner: FakeOwnerAPI, reads: Locked<[Int]> = Locked([])) -> CredentialsModel {
        CredentialsModel(
            api: owner, noteRead: { seq in reads.update { $0.append(seq) } }, now: { now }, timing: .quick,
            calendar: Fixtures.utc, locale: Fixtures.usEnglish)
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
        #expect(model.rows.allSatisfy { $0.kindLine == "Subscription login" })
        #expect(reads.value == [17])
    }

    private var clock: ResetClock {
        let at = now
        return ResetClock(now: { at }, calendar: Fixtures.utc, locale: Fixtures.usEnglish)
    }

    @Test("a ready login says it is signed in and answering; a signed-out one says so; one at its limit says until when")
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
        #expect(model.rows[0].chip.text == "Ready" && model.rows[0].usage == "Signed in and answering.")
        #expect(model.rows[1].chip.text == "Signed out" && model.rows[1].usage == "Not signed in.")
        let time = ResetTime.text(for: later, clock: clock)
        #expect(model.rows[2].chip.text == "At its limit")
        #expect(model.rows[2].usage == "At its limit until \(time).")
        #expect(model.rows[3].chip.text == "Ready")
        for row in model.rows { #expect(BannedTerms.found(in: row.usage + row.chip.text).isEmpty) }
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
        #expect(model.rows[0].chip.text == "At its limit")
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
        #expect(model.rows.map(\.chip.text) == ["Ready", "Ready"])
    }

    @Test("a signed-out account at its limit says it is signed out: signing in comes first")
    func signedOutBeatsLimit() async throws {
        let model = makeModel(owner([
            Fixtures.account(
                Fixtures.loginID, name: "Personal", state: .signedOut, since: now, until: now.addingTimeInterval(60), position: 1)
        ]))
        await model.load()
        try #require(model.rows.count == 1)
        #expect(model.rows[0].chip.text == "Signed out")
    }

    @Test("no row shows an email or a plan")
    func neverTheEmail() async throws {
        let model = makeModel(owner([
            Fixtures.account(
                Fixtures.loginID, name: "Personal", since: now, until: now.addingTimeInterval(60), position: 1,
                email: Fixtures.madeUpEmail, plan: Fixtures.madeUpPlan)
        ]))
        await model.load()
        let row = try #require(model.rows.first)
        for line in [row.name, row.kindLine, row.providerName, row.chip.text, row.usage] {
            #expect(!line.contains("@") && !line.contains("made up"), "\(line)")
        }
    }

    @Test("an API token is named as one, though none can be added yet")
    func tokenKind() async {
        let token = CredentialWithReading(
            credential: Credential(id: UUID(), kind: .apiToken, provider: .claudeApi, name: "Key", maskedLabel: "…abcd", position: 1))
        let model = makeModel(owner([token]))
        await model.load()
        #expect(model.rows[0].kindLine == "API token")
        #expect(model.rows[0].providerName == "Claude API")
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
        let model = CredentialsModel(api: owner, noteRead: { feed.noteRead(asOfSeq: $0) }, now: { now }, timing: .quick)
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
