import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

@MainActor
@Suite("AddCredentialModel")
struct AddCredentialModelTests {
    private let credentialID = UUID(uuidString: "12121212-1212-4212-8212-121212121212")!
    private let requestID = UUID(uuidString: "34343434-3434-4434-8434-343434343434")!
    private let installRequestID = UUID(uuidString: "56565656-5656-4656-8656-565656565656")!

    /// An owner that answers Add with `requestID` and then each answer of `script` in turn, the last one for
    /// every ask after it.
    private func owner(
        existing: [CredentialWithReading] = [], answers: [HelperRequestStatus]
    ) -> FakeOwnerAPI {
        let owner = Fixtures.owner(credentials: CredentialsList(credentials: existing, asOfSeq: 4))
        let remaining = Locked(answers)
        let id = credentialID
        let request = requestID
        owner.script {
            $0.addCredential = { _, key in
                .completed(AddCredentialResult(credentialID: id, helperRequestID: request), key: key.value, command: .addCredential)
            }
            $0.helperRequest = { _, _, _ in
                remaining.update { $0.count > 1 ? $0.removeFirst() : $0[0] }
            }
        }
        return owner
    }

    private func makeModel(_ owner: FakeOwnerAPI, added: Locked<Int> = Locked(0)) -> AddCredentialModel {
        AddCredentialModel(
            api: owner, credentialID: credentialID, onAdded: { added.update { $0 += 1 } }, timing: .quick)
    }

    private func passing(_ updated: Int = 5) -> HelperRequestStatus {
        Fixtures.request(
            requestID, state: .finished,
            progress: [
                Fixtures.progress(.toolInstalled, .passed), Fixtures.progress(.signedIn, .passed),
                Fixtures.progress(.testPrompt, .passed),
            ], result: Fixtures.finished(), updated: updated)
    }

    private func failing(
        _ check: HelperCheck, _ failure: HelperCheckFailure, install: InstallOffer? = nil
    ) -> HelperRequestStatus {
        Fixtures.request(
            requestID, state: .failed, progress: [Fixtures.progress(check, .failed, failure: failure, install: install)],
            result: Fixtures.finished(.failed, failing: [HelperCheckResult(check: check, passed: false, failure: failure)]),
            updated: 9)
    }

    private func start(_ model: AddCredentialModel, _ provider: Provider = .claude, name: String = "Personal") async {
        await model.load()
        model.pick(provider)
        model.name = name
    }

    // MARK: step 1

    @Test("step 1 offers the four logins, and Gemini and Grok already added are shown as Added and cannot be picked")
    func stepOne() async {
        let existing = [
            Fixtures.credential(Fixtures.loginID, name: "Personal", provider: .claude),
            Fixtures.credential(Fixtures.geminiLoginID, name: "Antigravity", provider: .gemini),
        ]
        let model = makeModel(owner(existing: existing, answers: [passing()]))
        await model.load()
        #expect(model.step == .pickProvider)
        #expect(model.providers.map(\.name) == ["Claude", "Codex", "Gemini", "Grok"])
        #expect(model.providers.map(\.isAdded) == [false, false, true, false])
        model.pick(.gemini)
        #expect(model.step == .pickProvider)
        model.pick(.claude)
        #expect(model.step == .nameIt)
        #expect(model.provider == .claude)
    }

    @Test("a Claude or Codex login can be added again: only one sign-in for the Mac is limited to one")
    func manyClaude() async {
        let model = makeModel(owner(existing: Fixtures.credentials().credentials, answers: [passing()]))
        await model.load()
        #expect(model.providers.map(\.isAdded) == [false, false, false, false])
    }

    @Test("Back returns to step 1, keeping the name typed")
    func back() async {
        let model = makeModel(owner(answers: [passing()]))
        await start(model, name: "Work")
        model.back()
        #expect(model.step == .pickProvider)
        model.pick(.codex)
        #expect(model.provider == .codex)
        #expect(model.name == "Work")
    }

    // MARK: step 2

    @Test("the name is required: with none, nothing is sent and the field says so")
    func nameRequired() async {
        let owner = owner(answers: [passing()])
        let model = makeModel(owner)
        await start(model, name: "   ")
        #expect(!model.canSignIn)
        await model.signIn()
        #expect(Fixtures.calls(owner, .addCredential).isEmpty)
        #expect(model.nameLine == "Give it a name.")
        model.name = "Personal"
        #expect(model.nameLine == nil)
        #expect(model.canSignIn)
    }

    @Test("Sign in sends the same credential id every time, the login kind, the provider and the name, with the four open fields null")
    func addBody() async {
        let owner = owner(answers: [passing()])
        let model = makeModel(owner)
        await start(model, .codex, name: " Team ")
        await model.signIn()
        guard case .object(let fields)? = Fixtures.calls(owner, .addCredential).first?.body else {
            Issue.record("Add credential was not sent")
            return
        }
        #expect(fields["credential_id"] == .string(credentialID.contractString))
        #expect(fields["kind"] == .string("login"))
        #expect(fields["provider"] == .string("codex"))
        #expect(fields["name"] == .string("Team"))
        for field in ["masked_label", "model", "effort", "strength_rank"] {
            #expect(fields[field] == .null, "\(field)")
        }
        #expect(fields.count == 8)
    }

    // MARK: the checks

    @Test("the three checks start waiting, then tick off as the helper reports them, and the sheet closes when all passed")
    func checksTick() async {
        let added = Locked(0)
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .running)], updated: 1),
            Fixtures.request(
                requestID, progress: [Fixtures.progress(.toolInstalled, .passed), Fixtures.progress(.signedIn, .running)], updated: 2),
            passing(3),
        ])
        let model = makeModel(owner, added: added)
        await start(model)
        #expect(model.checks.map(\.state) == [.waiting, .waiting, .waiting])
        let seen = Locked<[[HelperCheckState]]>([])
        let watching = Task { @MainActor in
            while !Task.isCancelled {
                let now = model.checks.map(\.state)
                if seen.value.last != now { seen.update { $0.append(now) } }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await model.signIn()
        watching.cancel()
        #expect(model.checks.map(\.state) == [.passed, .passed, .passed])
        #expect(model.step == .done)
        #expect(added.value == 1)
        #expect(model.failure == nil)
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 3)
        #expect(Fixtures.calls(owner, .getHelperRequest).allSatisfy { $0.path["id"] == requestID.contractString })
    }

    @Test("the check lines name the tool, in plain words")
    func checkWords() async {
        let model = makeModel(owner(answers: [passing()]))
        await start(model)
        #expect(model.checks.map(\.text) == [
            "Claude Code is installed", "You are signed in to Claude Code", "Claude Code answers a short test",
        ])
        let grok = makeModel(owner(answers: [passing()]))
        await start(grok, .grok)
        #expect(grok.checks.first?.text == "Grok Build is installed")
    }

    @Test("it asks again with the time of the last change it saw, so the answer waits for the next one")
    func asksAfterLastChange() async throws {
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .running)], updated: 4), passing(8),
        ])
        let asked = Locked<[Date?]>([])
        owner.script { answers in
            let before = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                asked.update { $0.append(after) }
                return try await before(id, wait, after)
            }
        }
        let model = makeModel(owner)
        await start(model)
        await model.signIn()
        // A count other than 2 fails the test here rather than crashing the
        // whole run on the index below.
        try #require(asked.value.count == 2)
        #expect(asked.value[0] == nil)
        #expect(asked.value[1] == Date(timeIntervalSince1970: 1_780_000_004))
    }

    @Test("waiting for the owner's sign-in says so, and goes away by itself once the sign-in is seen")
    func waitingForSignIn() async {
        let owner = owner(answers: [
            Fixtures.request(
                requestID, progress: [Fixtures.progress(.toolInstalled, .passed), Fixtures.progress(.signedIn, .waitingForSignIn)], updated: 1),
            passing(2),
        ])
        let model = makeModel(owner)
        await start(model)
        // The note is read each time the model asks again, which is after it
        // took in the answer before: no watcher has to catch it in time.
        let notes = Locked<[String?]>([])
        owner.script { answers in
            let before = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                let note = await MainActor.run { model.signInNote }
                notes.update { $0.append(note) }
                return try await before(id, wait, after)
            }
        }
        await model.signIn()
        #expect(notes.value == [nil, "Waiting for you to sign in in the window that opened"])
        #expect(model.signInNote == nil)
    }

    @Test("Gemini says to sign in to Antigravity on this Mac, and that leverage continues on its own")
    func geminiNote() async {
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.signedIn, .waitingForSignIn)], updated: 1),
            Fixtures.request(requestID, progress: [Fixtures.progress(.signedIn, .waitingForSignIn)], updated: 1),
        ])
        let model = makeModel(owner)
        await start(model, .gemini)
        let task = Task { await model.signIn() }
        #expect(await ShellFixtures.eventually { model.signInNote != nil })
        #expect(model.signInNote == "Sign in to Antigravity on this Mac. leverage continues on its own.")
        model.cancel()
        await task.value
    }

    // MARK: install

    private let offer = InstallOffer(installable: true, what: "Claude Code", sourceURL: URL(string: "https://example.invalid/install.sh"))

    @Test("a missing tool shows what will be installed and from where, with Install and Cancel")
    func installAsk() async {
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .waitingForInstall, install: offer)], updated: 1)
        ])
        let model = makeModel(owner)
        await start(model)
        let task = Task { await model.signIn() }
        #expect(await ShellFixtures.eventually { model.installAsk != nil })
        #expect(model.installAsk?.text == "Claude Code is not installed. leverage can install Claude Code from https://example.invalid/install.sh.")
        #expect(model.installAsk?.canInstall == true)
        model.cancel()
        await task.value
    }

    @Test("Install sends install_tool for that provider under a new key and says it is installing")
    func installSends() async {
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .waitingForInstall, install: offer)], updated: 1)
        ])
        let install = installRequestID
        owner.script { answers in
            let before = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                if id == install { return Fixtures.request(install, kind: .installTool, state: .finished, result: Fixtures.finished()) }
                return try await before(id, wait, after)
            }
            answers.installTool = { _, key in Fixtures.plain(.installTool, key: key, helperRequest: install) }
        }
        let model = makeModel(owner)
        await start(model)
        let task = Task { await model.signIn() }
        #expect(await ShellFixtures.eventually { model.installAsk != nil })
        await model.install()
        let sent = Fixtures.calls(owner, .installTool)
        #expect(sent.count == 1)
        #expect(sent.first?.path["provider"] == "claude")
        #expect(sent.first?.key != nil)
        #expect(model.isInstalling)
        #expect(model.installNote == "Installing Claude Code…")
        model.cancel()
        await task.value
    }

    @Test("when the install request fails, the sheet says so and Install can be tried again")
    func installFails() async {
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .waitingForInstall, install: offer)], updated: 1)
        ])
        let install = installRequestID
        owner.script { answers in
            let before = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                if id == install {
                    return Fixtures.request(install, kind: .installTool, state: .failed, result: Fixtures.finished(.failed))
                }
                return try await before(id, wait, after)
            }
            answers.installTool = { _, key in Fixtures.plain(.installTool, key: key, helperRequest: install) }
        }
        let model = makeModel(owner)
        await start(model)
        let task = Task { await model.signIn() }
        #expect(await ShellFixtures.eventually { model.installAsk != nil })
        await model.install()
        #expect(model.installFailure == "The install did not finish. Try again.")
        #expect(!model.isInstalling)
        await model.install()
        let keys = Fixtures.calls(owner, .installTool).map(\.key)
        #expect(keys.count == 2 && keys[0] != keys[1])
        model.cancel()
        await task.value
    }

    @Test("a tool leverage cannot install gets the plain sentence, and no Install button")
    func cannotInstall() async {
        let none = InstallOffer(installable: false, what: "Grok Build", sourceURL: nil)
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .waitingForInstall, install: none)], updated: 1)
        ])
        let model = makeModel(owner)
        await start(model, .grok)
        let task = Task { await model.signIn() }
        #expect(await ShellFixtures.eventually { model.installAsk != nil })
        #expect(model.installAsk?.text == "leverage can't install Grok Build yet. Install it, and leverage continues on its own.")
        #expect(model.installAsk?.canInstall == false)
        await model.install()
        #expect(Fixtures.calls(owner, .installTool).isEmpty)
        model.cancel()
        await task.value
    }

    // MARK: a failed check, and Retry

    @Test("each way a check can fail has one plain line naming the tool")
    func failureWords() async {
        let cases: [(HelperCheck, HelperCheckFailure, String)] = [
            (.toolInstalled, .notInstalled, "Claude Code is not installed."),
            (.signedIn, .notSignedIn, "Claude Code is not signed in."),
            (.testPrompt, .noAnswer, "Claude Code did not answer the short test."),
            (.testPrompt, .rejected, "Claude Code turned the short test down."),
            (.testPrompt, .unreachable, "Claude Code could not be reached. Check this Mac's internet connection."),
            (.signedIn, .timedOut, "Claude Code took too long."),
        ]
        for (check, failure, line) in cases {
            let model = makeModel(owner(answers: [failing(check, failure)]))
            await start(model)
            await model.signIn()
            #expect(model.failure == line, "\(failure)")
            #expect(model.step == .checking)
            #expect(model.checks.first { $0.check == check }?.state == .failed)
            #expect(BannedTerms.found(in: line).isEmpty)
        }
    }

    @Test("a failed check stays in the sheet with one line; nothing is added and the sheet does not close")
    func failureStays() async {
        let added = Locked(0)
        let model = makeModel(owner(answers: [failing(.signedIn, .notSignedIn)]), added: added)
        await start(model)
        await model.signIn()
        #expect(model.failure != nil)
        #expect(model.canRetry)
        #expect(added.value == 0)
    }

    @Test("Retry sends a new Add with a new key and the same credential id")
    func retry() async {
        let owner = owner(answers: [failing(.signedIn, .notSignedIn), passing()])
        let model = makeModel(owner)
        await start(model)
        await model.signIn()
        await model.retry()
        let adds = Fixtures.calls(owner, .addCredential)
        #expect(adds.count == 2)
        #expect(adds[0].key != adds[1].key)
        #expect(adds[0].body == adds[1].body)
        #expect(model.step == .done)
        #expect(model.failure == nil)
    }

    @Test("pressing Sign in again after the network failed sends the same command under the same key")
    func sameKeyAfterNetworkFailure() async {
        let owner = owner(answers: [passing()])
        let id = credentialID
        let request = requestID
        let attempts = Locked(0)
        owner.script {
            $0.addCredential = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
                return .completed(AddCredentialResult(credentialID: id, helperRequestID: request), key: key.value, command: .addCredential)
            }
        }
        let model = makeModel(owner)
        await start(model)
        await model.signIn()
        #expect(model.failure == ShellCopy.cannotReach.text)
        await model.signIn()
        let keys = Fixtures.calls(owner, .addCredential).map(\.key)
        #expect(keys.count == 2 && keys[0] == keys[1])
        #expect(model.step == .done)
    }

    @Test("a name already used goes back to step 2 with a plain line under the name field")
    func duplicateName() async {
        let owner = owner(answers: [passing()])
        let refusal = Refusal(code: .duplicateName, ruleID: nil, reason: nil)
        owner.script { $0.addCredential = { _, key in .refused(refusal, key: key.value, command: .addCredential) } }
        let model = makeModel(owner)
        await start(model)
        await model.signIn()
        #expect(model.step == .nameIt)
        #expect(model.nameLine == ShellCopy.refusalDuplicateName.text)
        #expect(model.failure == nil)
        model.name = "Another"
        #expect(model.nameLine == nil)
    }

    @Test("another refusal of Add shows the sentence for its code with Retry")
    func otherRefusal() async {
        let owner = owner(answers: [passing()])
        owner.script { $0.addCredential = { _, _ in throw TransportError(code: .invalid, message: "never shown") } }
        let model = makeModel(owner)
        await start(model, .gemini)
        await model.signIn()
        #expect(model.failure == ShellCopy.transportInvalid.text)
        #expect(model.canRetry)
    }

    @Test("a 401 while following ends the checks with the signed-out sentence")
    func signedOutWhileFollowing() async {
        let owner = owner(answers: [passing()])
        owner.script { $0.helperRequest = { _, _, _ in throw ShellFixtures.unauthenticated() } }
        let model = makeModel(owner)
        await start(model)
        await model.signIn()
        #expect(model.failure == ShellCopy.transportUnauthenticated.text)
    }

    @Test("a network error while following is waited out: the checks go on and finish")
    func networkWhileFollowing() async {
        let owner = owner(answers: [passing()])
        let attempts = Locked(0)
        owner.script { answers in
            let before = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                if attempts.update({ $0 += 1; return $0 }) <= 2 { throw URLError(.networkConnectionLost) }
                return try await before(id, wait, after)
            }
        }
        let model = makeModel(owner)
        await start(model)
        await model.signIn()
        #expect(model.step == .done)
    }

    @Test("Cancel stops following and does not add")
    func cancel() async {
        let added = Locked(0)
        let owner = owner(answers: [Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .running)], updated: 1)])
        let model = makeModel(owner, added: added)
        await start(model)
        let task = Task { await model.signIn() }
        #expect(await ShellFixtures.eventually { !Fixtures.calls(owner, .getHelperRequest).isEmpty })
        model.cancel()
        await task.value
        let asked = Fixtures.calls(owner, .getHelperRequest).count
        try? await Task.sleep(for: .milliseconds(40))
        #expect(Fixtures.calls(owner, .getHelperRequest).count == asked)
        #expect(added.value == 0)
    }

    // MARK: the screen

    @Test("the pop-up draws at each step, with an install question and with a failure, light and dark")
    func renders() async {
        let draw = { (model: AddCredentialModel, dark: Bool) in
            Fixtures.draws(
                AddCredentialForm(model: model, cancel: {}).environment(\.colorScheme, dark ? .dark : .light),
                width: 440, height: 520)
        }
        let one = makeModel(owner(existing: [Fixtures.credential(Fixtures.geminiLoginID, name: "A", provider: .gemini)], answers: [passing()]))
        await one.load()
        #expect(draw(one, false))
        #expect(draw(one, true))
        one.pick(.claude)
        #expect(draw(one, false))
        let failed = makeModel(owner(answers: [failing(.signedIn, .notSignedIn)]))
        await start(failed)
        await failed.signIn()
        #expect(draw(failed, false))
        let asking = makeModel(owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.toolInstalled, .waitingForInstall, install: offer)], updated: 1)
        ]))
        await start(asking)
        let task = Task { await asking.signIn() }
        #expect(await ShellFixtures.eventually { asking.installAsk != nil })
        #expect(draw(asking, false))
        asking.cancel()
        await task.value
    }
}
