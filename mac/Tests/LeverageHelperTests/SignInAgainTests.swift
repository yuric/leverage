import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// Sign in again (plan HE-36, HM-25, PV-4, CL-19): the `open_sign_in`
/// request opens the provider's own sign-in, watches the status until it
/// says signed in, runs the verify checks, and gives the result back to the
/// request loop. Against the stand-ins.
@Suite("Sign in again", .timeLimit(.minutes(Patience.minutes(1))))
struct SignInAgainTests {
    private func request(_ provider: Provider, credential: UUID = UUID()) -> HelperRequest {
        helperRequest(.openSignIn, credential: credential, params: .init(provider: provider, credentialKind: .login))
    }

    private func signInAgain(
        _ rig: HelperRig, prober: any TestPrompting = StandInPrompt(), timings: HelperTimings = fastTimings,
        log: Log = quietLog
    ) -> SignInAgain {
        SignInAgain(api: rig.api, settings: rig.settings, timings: timings, prober: prober, log: log)
    }

    private let allPassed = [
        HelperCheckResult(check: .toolInstalled, passed: true),
        HelperCheckResult(check: .signedIn, passed: true),
        HelperCheckResult(check: .testPrompt, passed: true),
    ]

    /// The account's folder as an earlier add left it: there, and signed out.
    private func signedOutFolder(_ rig: HelperRig, _ provider: Provider, _ credential: UUID) throws -> URL? {
        ProviderCatalog.entry(for: provider.rawValue)?.accountFolderVariable.value == nil
            ? nil : try rig.folders.createFresh(for: credential)
    }

    @Test(
        "the provider's own sign-in is started, the status is watched, the checks run, and the result is finished",
        arguments: [Provider.claude, .codex, .grok])
    func signsInAndVerifies(provider: Provider) async throws {
        let rig = try HelperRig()
        let credential = UUID()
        let folder = try signedOutFolder(rig, provider, credential)
        let captured = CapturedLog()
        let request = request(provider, credential: credential)

        let result = await signInAgain(rig, log: captured.log).run(request)

        #expect(result.outcome == .finished)
        #expect(result.checks == allPassed)
        #expect(result.toolVersion?.isEmpty == false)
        #expect(result.plan == nil && result.accountEmail == nil)
        let entry = try #require(ProviderCatalog.entry(for: provider.rawValue))
        let calls = try rig.tools.calls().filter { $0.tool == entry.toolName }
        #expect(calls.contains { $0.argv == entry.signIn.value.arguments })
        let states = rig.progress(of: request.id).filter { $0.check == .signedIn }.map(\.state)
        #expect(states.contains(.waitingForSignIn))
        #expect(states.last == .passed)
        #expect(rig.tools.isSignedIn(entry.toolName, accountFolder: folder))
        if let folder {
            // The account's own folder, never the Mac's one sign-in.
            #expect(!rig.tools.isSignedIn(entry.toolName))
            for call in calls where call.argv != ["--version"] {
                #expect(call.env[entry.accountFolderVariable.value!] == folder.path)
            }
        }
        // The status output names a made-up account; none of it leaves.
        #expect(!rig.everythingSent().contains(StandIns.statusEmail))
        #expect(!captured.text.contains(StandIns.statusEmail))
        #expect(!captured.text.contains(StandIns.statusOrganisation))
    }

    @Test("Gemini has no sign-in command: the repeated test prompt notices the owner's sign-in")
    func geminiByRepeatedPrompt() async throws {
        let rig = try HelperRig()
        let request = request(.gemini)
        let signer = Task {
            _ = await eventually { rig.progress(of: request.id).contains { $0.state == .waitingForSignIn } }
            try rig.tools.signIn("agy")
        }

        let result = await signInAgain(rig).run(request)
        try await signer.value

        #expect(result.outcome == .finished)
        #expect(result.checks == allPassed)
        let prompts = try rig.tools.calls().filter { $0.tool == "agy" && $0.argv.first == "-p" }
        #expect(prompts.count >= 2)
        #expect(rig.folders.existing(for: request.credentialID!) == nil)
    }

    @Test("an account that is signed in already opens no sign-in, and the checks pass")
    func alreadySignedIn() async throws {
        let rig = try HelperRig()
        let credential = UUID()
        let folder = try rig.folders.createFresh(for: credential)
        try rig.tools.signIn("claude", accountFolder: folder)

        let result = await signInAgain(rig).run(request(.claude, credential: credential))

        #expect(result.outcome == .finished)
        #expect(result.checks == allPassed)
        #expect(try rig.tools.calls().filter { $0.argv == ["auth", "login"] }.isEmpty)
    }

    @Test("a sign-in that never comes fails the sign-in check when the wait ends")
    func neverSignedIn() async throws {
        let rig = try HelperRig()
        var timings = fastTimings
        timings.waitAtMost = .milliseconds(600)
        let request = request(.gemini)

        let result = await signInAgain(rig, timings: timings).run(request)

        #expect(result.outcome == .failed)
        #expect(result.checks.last == HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn))
        #expect(rig.progress(of: request.id).last
            == HelperCheckProgress(check: .signedIn, state: .failed, failure: .notSignedIn))
    }

    @Test("a test prompt that gets no answer fails with no_answer, and the account's folder is kept")
    func noAnswerKeepsTheFolder() async throws {
        let rig = try HelperRig()
        let credential = UUID()
        _ = try rig.folders.createFresh(for: credential)

        let result = await signInAgain(rig, prober: FixedPrompt(answer: false)).run(request(.claude, credential: credential))

        #expect(result.outcome == .failed)
        #expect(result.checks.last == HelperCheckResult(check: .testPrompt, passed: false, failure: .noAnswer))
        #expect(result.checks.contains(HelperCheckResult(check: .signedIn, passed: true)))
        #expect(rig.folders.existing(for: credential) != nil)
    }

    @Test("a login whose folder is gone gets a new one, and is signed in there, never to the Mac's sign-in")
    func missingFolderIsMadeAgain() async throws {
        let rig = try HelperRig()
        let credential = UUID()

        let result = await signInAgain(rig).run(request(.codex, credential: credential))

        #expect(result.outcome == .finished)
        let folder = try #require(rig.folders.existing(for: credential))
        #expect(rig.tools.isSignedIn("codex", accountFolder: folder))
        #expect(!rig.tools.isSignedIn("codex"))
    }

    @Test("a tool that is not installed fails at once, naming what would be installed; nothing waits")
    func missingToolFailsAtOnce() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        let credential = UUID()
        _ = try rig.folders.createFresh(for: credential)
        let request = request(.claude, credential: credential)

        let result = await signInAgain(rig).run(request)

        #expect(result.outcome == .failed)
        #expect(result.checks == [HelperCheckResult(check: .toolInstalled, passed: false, failure: .notInstalled)])
        #expect(!rig.progress(of: request.id).contains { $0.state == .waitingForInstall })
        #expect(rig.folders.existing(for: credential) != nil)
    }

    @Test("a request with no credential or no provider fails")
    func incompleteRequestFails() async throws {
        let rig = try HelperRig()

        let noCredential = await signInAgain(rig).run(
            helperRequest(.openSignIn, params: .init(provider: .claude, credentialKind: .login)))
        let noProvider = await signInAgain(rig).run(helperRequest(.openSignIn, credential: UUID()))

        #expect(noCredential.outcome == .failed)
        #expect(noProvider.outcome == .failed)
        #expect(try rig.tools.calls().filter { $0.argv == ["auth", "login"] }.isEmpty)
    }
}
