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

    private func makeModel(
        _ owner: FakeOwnerAPI, added: Locked<Int> = Locked(0), runtime: FakeAppRuntime = FakeAppRuntime()
    ) -> AddCredentialModel {
        AddCredentialModel(
            api: owner, credentialID: credentialID, onAdded: { added.update { $0 += 1 } }, timing: .quick,
            helper: runtime.helper)
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
        #expect(model.providers.prefix(4).map(\.name) == ["Claude", "Codex", "Gemini", "Grok"])
        #expect(model.providers.prefix(4).map(\.isAdded) == [false, false, true, false])
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
        #expect(model.providers.prefix(4).map(\.isAdded) == [false, false, false, false])
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

    @Test("Sign in sends the same credential id every time, the login kind, the provider and the name, with no label and no effort")
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
        #expect(fields["masked_label"] == .null)
        #expect(fields["effort"] == .null)
        #expect(fields.count == 8)
    }

    @Test("Add credential sends the catalog's default model for Claude and Grok, and null for Codex and Gemini (HE-5)")
    func addSendsDefaultModel() async {
        var sent: [Provider: JSONValue] = [:]
        for provider in [Provider.claude, .codex, .gemini, .grok] {
            let owner = owner(answers: [passing()])
            let model = makeModel(owner)
            await start(model, provider, name: "Personal")
            await model.signIn()
            guard case .object(let fields)? = Fixtures.calls(owner, .addCredential).first?.body else {
                Issue.record("Add credential was not sent for \(provider)")
                continue
            }
            sent[provider] = fields["model"]
        }
        let claude = ProviderCatalog.entry(for: "claude")?.defaultModel?.value
        let grok = ProviderCatalog.entry(for: "grok")?.defaultModel?.value
        #expect(claude?.isEmpty == false && grok?.isEmpty == false)
        #expect(sent[.claude] == claude.map { JSONValue.string($0) })
        #expect(sent[.grok] == grok.map { JSONValue.string($0) })
        #expect(sent[.codex] == .null)
        #expect(sent[.gemini] == .null)
    }

    @Test("Add credential sends strength rank 1, the agents' default, and no effort, for every provider (HE-5)")
    func addSendsRankOne() async {
        for provider in [Provider.claude, .codex, .gemini, .grok] {
            let owner = owner(answers: [passing()])
            let model = makeModel(owner)
            await start(model, provider, name: "Personal")
            await model.signIn()
            guard case .object(let fields)? = Fixtures.calls(owner, .addCredential).first?.body else {
                Issue.record("Add credential was not sent for \(provider)")
                continue
            }
            #expect(fields["strength_rank"] == .number(1), "\(provider)")
            #expect(fields["effort"] == .null, "\(provider)")
        }
    }

    @Test("a Retry sends the same model and rank again")
    func retryKeepsModel() async throws {
        let owner = owner(answers: [failing(.testPrompt, .noAnswer), passing()])
        let model = makeModel(owner)
        await start(model, .claude)
        await model.signIn()
        await model.retry()
        let bodies = Fixtures.calls(owner, .addCredential).compactMap(\.body)
        try #require(bodies.count == 2)
        guard case .object(let first) = bodies[0], case .object(let second) = bodies[1] else { return }
        #expect(first["model"] == second["model"] && first["model"] != .null)
        #expect(first["strength_rank"] == second["strength_rank"])
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

    // MARK: API tokens

    private nonisolated static let madeUpToken = "LVRG-TOKEN-000000000010"

    private func tokenPassed() -> HelperRequestStatus {
        Fixtures.request(
            requestID, state: .finished, progress: [Fixtures.progress(.tokenWorks, .passed)],
            result: Fixtures.finished())
    }

    private nonisolated static func isExpectedSend(_ message: LocalHelperMessage?, credentialID: UUID, provider: Provider) -> Bool {
        guard case .token(let id, let selected, let token)? = message else { return false }
        return id == credentialID && selected == provider && token == madeUpToken
    }

    private static func holdsToken(_ model: AddCredentialModel) -> Bool {
        // Inspect values the model owns, without walking into the injected fakes.
        func containsToken(_ value: Any) -> Bool {
            if let string = value as? String { return string.contains(madeUpToken) }
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle != .class && mirror.children.contains { containsToken($0.value) }
        }
        return Mirror(reflecting: model).children.contains { containsToken($0.value) }
    }

    @Test("the picker lists all four logins and five API token providers, with names from the catalog")
    func tokenChoices() async {
        let logins: [Provider] = [.claude, .codex, .gemini, .grok]
        let tokens = ProviderCatalog.tokenEntries
        let model = makeModel(owner(existing: [
            Fixtures.credential(Fixtures.geminiLoginID, name: "Personal", provider: .gemini)
        ], answers: [tokenPassed()]))
        await model.load()
        #expect(tokens.count == 5)
        #expect(model.providers.map(\.provider) == logins + tokens.map(\.provider))
        #expect(model.providers.map(\.name) ==
            logins.compactMap { ProviderCatalog.entry(for: $0.rawValue)?.displayName } + tokens.map(\.displayName))
        #expect(model.providers.filter(\.isAdded).map(\.provider) == [.gemini])
    }

    @Test("step 2 asks for a name and a hidden token and offers Add")
    func tokenForm() async throws {
        let owner = owner(answers: [tokenPassed()])
        let model = makeModel(owner)
        await start(model, .openrouter)
        #expect(model.step == .nameIt)
        #expect(!model.canAddToken)
        await model.addToken()
        #expect(Fixtures.calls(owner, .addCredential).count == 0)
        model.name = ""
        model.token = Self.madeUpToken
        #expect(!model.canAddToken)
        model.name = "Personal"
        #expect(model.canAddToken)
        #expect(!model.canSignIn)
        await model.signIn()
        #expect(Fixtures.calls(owner, .addCredential).count == 0)
        #expect(Fixtures.draws(AddCredentialForm(model: model, cancel: {}), width: 440, height: 520))
        model.cancel()

        // The renderer checks layout but cannot tell a secure field from a plain one.
        let sheet = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LeverageApp/Credentials/AddCredentialSheet.swift")
        let code = LiteralScanner.code(of: try String(contentsOf: sheet, encoding: .utf8))
        let hasName = code.contains("TextField(CredentialsCopy.namePlaceholder.text, text: $model.name)")
        let hasSecureToken = code.contains("SecureField(AddTokenCopy.tokenLabel.text, text: $model.token)")
        let hasPlainToken = code.contains("TextField(AddTokenCopy.tokenLabel.text, text: $model.token)")
        let hasAdd = code.contains("Button(AddTokenCopy.add.text)")
        #expect(hasName)
        #expect(hasSecureToken)
        #expect(!hasPlainToken)
        #expect(hasAdd)
    }

    @Test("Add sends the token to the helper first and only the fixed mask to the API, then clears the token on a pass")
    func tokenAdd() async throws {
        let runtime = FakeAppRuntime()
        let owner = owner(answers: [
            Fixtures.request(requestID, progress: [Fixtures.progress(.tokenWorks, .running)], updated: 1),
            tokenPassed(),
        ])
        let id = credentialID
        let helperSentFirst = Locked(false)
        owner.script { answers in
            let add = answers.addCredential
            answers.addCredential = { request, key in
                let messages = runtime.fakeHelper.messages.value
                helperSentFirst.value = messages.count == 1 && Self.isExpectedSend(messages.first, credentialID: id, provider: .openaiApi)
                return try await add(request, key)
            }
        }
        let added = Locked(0)
        let model = makeModel(owner, added: added, runtime: runtime)
        await start(model, .openaiApi, name: "  Team  ")
        model.token = "  " + Self.madeUpToken + "\n"
        #expect(Self.holdsToken(model))
        #expect(model.checks.map(\.state) == [.waiting])
        #expect(model.checks.map(\.check) == [.tokenWorks])
        let sawRunning = Locked(false)
        owner.script { answers in
            let read = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                if after != nil {
                    sawRunning.value = await MainActor.run { model.checks.map(\.state) == [.running] }
                }
                return try await read(id, wait, after)
            }
        }
        await model.addToken()
        #expect(helperSentFirst.value)
        #expect(sawRunning.value)
        #expect(model.step == .done)
        #expect(model.checks.map(\.state) == [.passed])
        #expect(added.value == 1)
        #expect(!Self.holdsToken(model))
        let adds = Fixtures.calls(owner, .addCredential)
        try #require(adds.count == 1)
        let body = try #require(adds.first?.body)
        let encoded = try JSONEncoder().encode(body)
        let containsTokenMarker = String(decoding: encoded, as: UTF8.self).contains("LVRG-TOKEN-")
        #expect(!containsTokenMarker)
        // Compare fields without printing the actual body on a failure.
        let expected: JSONValue = .object([
            "credential_id": .string(id.contractString), "kind": .string("api_token"), "provider": .string("openai_api"),
            "name": .string("Team"), "masked_label": .string("••••••••"), "model": .null, "effort": .null,
            "strength_rank": .null,
        ])
        let onlyExpectedFields = body == expected
        #expect(onlyExpectedFields)
    }

    @Test("a failed token check has its own line and Retry sends the same ID and a new key")
    func tokenRetry() async throws {
        let cases: [(HelperCheckFailure, String)] = [
            (.noAnswer, "OpenRouter could not complete the token check."),
            (.tokenStoreUnavailable, "leverage could not access this Mac’s Keychain. Check Keychain access and try again."),
            (.providerMismatch, "Check the token’s provider and add it again. Remove the old token first if it is listed."),
            (.rejected, "OpenRouter rejected this token."),
            (.unreachable, "OpenRouter could not be reached. Check this Mac's internet connection."),
            (.timedOut, "OpenRouter took too long to check the token."),
            (.notSignedIn, "This token is missing on this Mac."),
        ]
        for (failure, line) in cases {
            let runtime = FakeAppRuntime()
            let owner = owner(answers: [failing(.tokenWorks, failure), tokenPassed()])
            let id = credentialID
            let sendsAtAdd = Locked<[Int]>([])
            owner.script { answers in
                let add = answers.addCredential
                answers.addCredential = { request, key in
                    sendsAtAdd.update { $0.append(runtime.fakeHelper.messages.value.count) }
                    return try await add(request, key)
                }
            }
            let model = makeModel(owner, runtime: runtime)
            await start(model, .openrouter)
            model.token = Self.madeUpToken
            await model.addToken()
            #expect(model.step == .checking)
            #expect(model.checks.map(\.state) == [.failed])
            #expect(model.failure == line, "\(failure)")
            #expect(model.canRetry)
            #expect(model.signInNote == nil)
            #expect(model.installAsk == nil)
            await model.retry()
            #expect(sendsAtAdd.value == [1, 2])
            let resendsSameToken = runtime.fakeHelper.messages.value.allSatisfy {
                Self.isExpectedSend($0, credentialID: id, provider: .openrouter)
            }
            #expect(resendsSameToken)
            let adds = Fixtures.calls(owner, .addCredential)
            try #require(adds.count == 2)
            #expect(adds[0].key != adds[1].key)
            let sameBody = adds[0].body == adds[1].body
            #expect(sameBody)
            #expect(model.step == .done)
            #expect(model.failure == nil)
            #expect(!Self.holdsToken(model))
        }
    }

    @Test("a helper that cannot take the token leaves the sheet open with Retry and sends no Add")
    func tokenHelperDown() async {
        let runtime = FakeAppRuntime()
        runtime.fakeHelper.sendFailure.value = HelperSendError.notRunning
        let owner = owner(answers: [tokenPassed()])
        let model = makeModel(owner, runtime: runtime)
        await start(model, .geminiApi)
        model.token = Self.madeUpToken
        await model.addToken()
        #expect(runtime.fakeHelper.messages.value.count == 1)
        #expect(Fixtures.calls(owner, .addCredential).count == 0)
        #expect(model.failure == "Agents are not running on this Mac, so leverage cannot check the token.")
        #expect(model.canRetry)
        runtime.fakeHelper.sendFailure.value = nil
        await model.retry()
        #expect(runtime.fakeHelper.messages.value.count == 2)
        #expect(Fixtures.calls(owner, .addCredential).count == 1)
        #expect(model.step == .done)
    }

    @Test("Retry after a lost Add response resends the local token and keeps the request key")
    func tokenNetworkRetry() async throws {
        let runtime = FakeAppRuntime()
        let owner = owner(answers: [tokenPassed()])
        let attempts = Locked(0)
        owner.script { answers in
            let add = answers.addCredential
            answers.addCredential = { request, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.networkConnectionLost) }
                return try await add(request, key)
            }
        }
        let model = makeModel(owner, runtime: runtime)
        await start(model, .claudeApi)
        model.token = Self.madeUpToken
        await model.addToken()
        #expect(model.canRetry)
        await model.retry()
        let keys = Fixtures.calls(owner, .addCredential).map(\.key)
        try #require(keys.count == 2)
        #expect(keys[0] == keys[1])
        #expect(runtime.fakeHelper.messages.value.count == 2)
        #expect(!Self.holdsToken(model))
        #expect(model.step == .done)
    }

    @Test("Retry resumes an accepted Add if the helper check could not be read")
    func tokenRetryFollowing() async {
        let runtime = FakeAppRuntime()
        let owner = owner(answers: [tokenPassed()])
        let attempts = Locked(0)
        owner.script { answers in
            let read = answers.helperRequest
            answers.helperRequest = { id, wait, after in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw LeverageClientError.invalidBody }
                return try await read(id, wait, after)
            }
        }
        let model = makeModel(owner, runtime: runtime)
        await start(model, .claudeApi)
        model.token = Self.madeUpToken
        await model.addToken()
        #expect(model.canRetry)
        await model.retry()
        #expect(runtime.fakeHelper.messages.value.count == 1)
        #expect(Fixtures.calls(owner, .addCredential).count == 1)
        #expect(Fixtures.calls(owner, .getHelperRequest).map { $0.path["id"] } ==
            [requestID.contractString, requestID.contractString])
        #expect(model.step == .done)
        #expect(!Self.holdsToken(model))
    }

    @Test("a successful poll that returns after Cancel cannot finish the sheet")
    func tokenCancelDuringCheck() async {
        let passed = tokenPassed()
        let owner = owner(answers: [passed])
        let runtime = FakeAppRuntime()
        let (holdPoll, release) = AsyncStream<Void>.makeStream()
        owner.script { answers in
            answers.helperRequest = { _, _, _ in
                for await _ in holdPoll { break }
                return passed
            }
        }
        let added = Locked(0)
        let model = makeModel(owner, added: added, runtime: runtime)
        await start(model, .claudeApi)
        model.token = Self.madeUpToken
        var returned = false
        let run = Task {
            await model.addToken()
            returned = true
        }
        #expect(await ShellFixtures.eventually { returned || !Fixtures.calls(owner, .getHelperRequest).isEmpty })
        #expect(Fixtures.calls(owner, .getHelperRequest).count == 1)
        model.cancel()
        release.finish()
        await run.value
        #expect(added.value == 0)
        #expect(model.checks.map(\.state) == [.waiting])
        #expect(!Self.holdsToken(model))
    }

    @Test("Cancel during the local send discards the token and prevents Add")
    func tokenCancelDuringSend() async {
        let runtime = FakeAppRuntime()
        let (duringSend, release) = AsyncStream<Void>.makeStream()
        let helper = PausedTokenSend(base: runtime.fakeHelper, duringSend: duringSend)
        let owner = owner(answers: [tokenPassed()])
        let model = AddCredentialModel(
            api: owner, credentialID: credentialID, onAdded: {}, timing: .quick, helper: helper)
        await start(model, .claudeApi)
        model.token = Self.madeUpToken
        var returned = false
        let run = Task {
            await model.addToken()
            returned = true
        }
        #expect(await ShellFixtures.eventually { returned || !runtime.fakeHelper.messages.value.isEmpty })
        #expect(runtime.fakeHelper.messages.value.count == 1)
        model.cancel()
        #expect(!Self.holdsToken(model))
        release.finish()
        await run.value
        #expect(Fixtures.calls(owner, .addCredential).count == 0)
    }

    @Test("Cancel discards the pasted token before or after a failed check")
    func tokenCancel() async {
        for afterFailure in [false, true] {
            let runtime = FakeAppRuntime()
            let owner = owner(answers: [failing(.tokenWorks, .rejected)])
            let model = makeModel(owner, runtime: runtime)
            await start(model, .openrouter)
            model.token = Self.madeUpToken
            if afterFailure { await model.addToken() }
            #expect(Self.holdsToken(model))
            model.cancel()
            #expect(!Self.holdsToken(model))
            await model.retry()
            #expect(runtime.fakeHelper.messages.value.count == (afterFailure ? 1 : 0))
            #expect(Fixtures.calls(owner, .addCredential).count == (afterFailure ? 1 : 0))
        }
    }

    @Test("a token copied into the name stays on the Mac")
    func tokenInName() async {
        let runtime = FakeAppRuntime()
        let owner = owner(answers: [tokenPassed()])
        let model = makeModel(owner, runtime: runtime)
        await start(model, .grokApi, name: "Team \(Self.madeUpToken)")
        model.token = Self.madeUpToken
        await model.addToken()
        #expect(model.step == .nameIt)
        #expect(model.nameLine == "Give it a name that does not include the token.")
        #expect(Fixtures.calls(owner, .addCredential).count == 0)
        #expect(runtime.fakeHelper.messages.value.count == 0)
        model.back()
        #expect(!Self.holdsToken(model))
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

/// Let the fake deliver a successful local send after the model cancels.
private final class PausedTokenSend: HelperSupervising {
    let base: FakeHelper
    let duringSend: AsyncStream<Void>

    init(base: FakeHelper, duringSend: AsyncStream<Void>) {
        self.base = base
        self.duringSend = duringSend
    }

    func state() async -> HelperState { await base.state() }
    func start(apiBaseURL: URL, issuer: any HelperTokenIssuing) async -> HelperState {
        await base.start(apiBaseURL: apiBaseURL, issuer: issuer)
    }
    func tryAgain() async -> HelperState { await base.tryAgain() }
    func stop() async { await base.stop() }

    func send(_ message: LocalHelperMessage) async throws {
        try await base.send(message)
        for await _ in duringSend { break }
    }
}
