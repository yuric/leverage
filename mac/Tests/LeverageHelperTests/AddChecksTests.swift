import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// The three login checks of Add credential and Verify (L602-L606, IN-23,
/// PV-3, PV-4, CL-19), per provider, against the stand-ins.
@Suite("Add checks", .timeLimit(.minutes(Patience.minutes(1))))
struct AddChecksTests {
    private func addRequest(_ provider: Provider, credential: UUID = UUID()) -> HelperRequest {
        helperRequest(.runAddChecks, credential: credential, params: .init(provider: provider, credentialKind: .login))
    }

    private func verifyRequest(_ provider: Provider, credential: UUID) -> HelperRequest {
        helperRequest(.verify, credential: credential, params: .init(provider: provider, credentialKind: .login))
    }

    private func allPassed(_ result: HelperRequestResult) -> Bool {
        result.outcome == .finished
            && result.checks == [
                HelperCheckResult(check: .toolInstalled, passed: true),
                HelperCheckResult(check: .signedIn, passed: true),
                HelperCheckResult(check: .testPrompt, passed: true),
            ]
    }

    // MARK: Signed out, then signed in on its own

    @Test(
        "installed, signed out, then signed in in the provider's own window: the add goes on with no Retry",
        arguments: [Provider.claude, .codex, .grok])
    func signsInOnItsOwn(provider: Provider) async throws {
        let rig = try HelperRig()
        let request = addRequest(provider)

        let result = await rig.checks().add(request)

        #expect(allPassed(result))
        #expect(result.toolVersion?.isEmpty == false)
        // IN-25: the helper reports no plan and no email in this milestone.
        #expect(result.plan == nil && result.accountEmail == nil)

        let states = rig.progress(of: request.id).filter { $0.check == .signedIn }.map(\.state)
        #expect(states.contains(.waitingForSignIn))
        #expect(states.last == .passed)

        let entry = ProviderCatalog.entry(for: provider.rawValue)!
        let calls = try rig.tools.calls().filter { $0.tool == entry.toolName }
        #expect(calls.contains { $0.argv == entry.signIn.value.arguments })
    }

    @Test("a login with its own folder is signed in to the folder the helper made, never to the Mac's")
    func signsInToItsOwnFolder() async throws {
        let rig = try HelperRig()
        let credential = UUID()

        let result = await rig.checks().add(addRequest(.claude, credential: credential))

        #expect(allPassed(result))
        let folder = try #require(rig.folders.existing(for: credential))
        #expect(rig.tools.isSignedIn("claude", accountFolder: folder))
        #expect(!rig.tools.isSignedIn("claude"))
        // Every call but the version's is about this account.
        for call in try rig.tools.calls() where call.tool == "claude" && call.argv != ["--version"] {
            #expect(call.env["CLAUDE_CONFIG_DIR"] == folder.path)
        }
    }

    @Test("Gemini has no status command: the repeated test prompt notices the sign-in and goes on")
    func geminiByRepeatedPrompt() async throws {
        let rig = try HelperRig()
        let request = addRequest(.gemini)
        // The owner signs in only once the helper says it is waiting, so
        // the first prompt is always answered signed out.
        let signer = Task {
            _ = await eventually { rig.progress(of: request.id).contains { $0.state == .waitingForSignIn } }
            try rig.tools.signIn("agy")
        }

        let result = await rig.checks().add(request)
        try await signer.value

        #expect(allPassed(result))
        let prompts = try rig.tools.calls().filter { $0.tool == "agy" && $0.argv.first == "-p" }
        #expect(prompts.count >= 2)
        let states = rig.progress(of: request.id).filter { $0.check == .signedIn }.map(\.state)
        #expect(states.contains(.waitingForSignIn))
        // Antigravity is one sign-in for the Mac: no folder is made for it.
        #expect(rig.folders.existing(for: request.credentialID!) == nil)
    }

    @Test("a Gemini sign-in that never comes fails as not signed in when the wait ends")
    func geminiNeverSignedIn() async throws {
        let rig = try HelperRig()
        var timings = fastTimings
        timings.waitAtMost = .milliseconds(600)
        let request = addRequest(.gemini)

        let result = await rig.checks(timings: timings).add(request)

        #expect(result.outcome == .failed)
        #expect(result.checks.last == HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn))
        #expect(rig.progress(of: request.id).last
            == HelperCheckProgress(check: .signedIn, state: .failed, failure: .notSignedIn))
    }

    // MARK: Missing tool

    @Test("a missing tool names what would be installed and from where, and fails when the wait ends")
    func missingToolNamesWhatAndFromWhere() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        var timings = fastTimings
        timings.waitAtMost = .milliseconds(500)
        let request = addRequest(.claude)

        let result = await rig.checks(timings: timings).add(request)

        let offer = InstallOffer(
            installable: true, what: "Claude Code", sourceURL: URL(string: "https://claude.ai/install.sh"))
        let progress = rig.progress(of: request.id).filter { $0.check == .toolInstalled }
        #expect(progress.contains(HelperCheckProgress(check: .toolInstalled, state: .waitingForInstall, install: offer)))
        #expect(progress.last
            == HelperCheckProgress(check: .toolInstalled, state: .failed, failure: .notInstalled, install: offer))
        #expect(result.outcome == .failed)
        #expect(result.checks == [HelperCheckResult(check: .toolInstalled, passed: false, failure: .notInstalled)])
        // CL-18: the folder made for the add is gone.
        #expect(rig.folders.existing(for: request.credentialID!) == nil)
    }

    @Test("a provider leverage cannot install keeps looking, and goes on when the tool appears")
    func noInstallerKeepsLooking() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        let request = addRequest(.grok)
        let into = rig.toolDir.appendingPathComponent("grok")
        let launcher = "#!/bin/sh\nexec '\(rig.tools.tool("grok").path)' \"$@\"\n"
        // The owner installs it by hand once the helper says it is waiting.
        let installer = Task {
            _ = await eventually { rig.progress(of: request.id).contains { $0.state == .waitingForInstall } }
            try Data(launcher.utf8).write(to: into)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: into.path)
        }

        let result = await rig.checks().add(request)
        try await installer.value

        let waiting = rig.progress(of: request.id).first { $0.state == .waitingForInstall }
        #expect(waiting?.install == InstallOffer(installable: false, what: "Grok Build", sourceURL: nil))
        #expect(allPassed(result))
    }

    // MARK: Failures

    @Test("a test prompt that gets no answer fails the add, and the folder made for it is deleted")
    func noAnswerDeletesTheFolder() async throws {
        let rig = try HelperRig()
        let request = addRequest(.codex)

        let result = await rig.checks(prober: FixedPrompt(answer: false)).add(request)

        #expect(result.outcome == .failed)
        #expect(result.checks.last == HelperCheckResult(check: .testPrompt, passed: false, failure: .noAnswer))
        #expect(rig.folders.existing(for: request.credentialID!) == nil)
    }

    // MARK: What leaves the helper

    @Test("no leverage token reaches a tool, and nothing a status prints reaches the server")
    func nothingSecretLeaves() async throws {
        let rig = try HelperRig()

        _ = await rig.checks().add(addRequest(.claude))
        _ = await rig.checks().add(addRequest(.codex))
        _ = await rig.checks().add(addRequest(.grok))

        // What each tool saw (the shell and the system's python3 add a few
        // variables of their own, so this looks for what must not be there).
        for call in try rig.tools.calls() {
            #expect(!call.env.keys.contains { $0.hasPrefix("LEVERAGE_") })
            #expect(call.env["SOME_OTHER_SECRET"] == nil)
            #expect(!call.env.values.contains { $0.contains("lvh_") || $0.contains("lvo_") || $0.contains("lvs_") })
        }
        // What the helper gives a tool is exactly the allow-list (CL-10).
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        let claude = ProviderCatalog.entry(for: "claude")!
        let built = locator.toolEnvironment(
            claude, toolPath: rig.tools.tool("claude").path, accountFolder: rig.folder.path("account"))
        #expect(Set(built.keys) == ["PATH", "HOME", "TMPDIR", "LANG", "USER", "CLAUDE_CONFIG_DIR"])
        let codex = ProviderCatalog.entry(for: "codex")!
        #expect(Set(locator.toolEnvironment(codex, toolPath: rig.tools.tool("codex").path, accountFolder: nil).keys)
            == ["PATH", "HOME", "TMPDIR", "LANG"])
        let sent = rig.everythingSent()
        #expect(!sent.contains(StandIns.statusEmail))
        #expect(!sent.contains(StandIns.statusOrganisation))
        #expect(!sent.contains("lvh_"))
    }

    // MARK: Verify

    @Test("Verify passes a signed-in login and keeps its folder")
    func verifyPasses() async throws {
        let rig = try HelperRig()
        let credential = UUID()
        let folder = try rig.folders.createFresh(for: credential)
        try rig.tools.signIn("claude", accountFolder: folder)

        let result = await rig.checks().verify(verifyRequest(.claude, credential: credential))

        #expect(allPassed(result))
        #expect(rig.folders.existing(for: credential) != nil)
    }

    @Test("Verify of a signed-out login fails as not signed in, opens no sign-in, and keeps the folder")
    func verifySignedOut() async throws {
        let rig = try HelperRig()
        let credential = UUID()
        _ = try rig.folders.createFresh(for: credential)

        let result = await rig.checks().verify(verifyRequest(.claude, credential: credential))

        #expect(result.outcome == .failed)
        #expect(result.checks.last == HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn))
        #expect(try !rig.tools.calls().contains { $0.argv == ["auth", "login"] })
        #expect(rig.folders.existing(for: credential) != nil)
    }

    @Test("Verify with no folder for the login fails as not signed in and makes none")
    func verifyWithoutFolder() async throws {
        let rig = try HelperRig()
        let credential = UUID()

        let result = await rig.checks().verify(verifyRequest(.codex, credential: credential))

        #expect(result.outcome == .failed)
        #expect(result.checks.last == HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn))
        #expect(rig.folders.existing(for: credential) == nil)
    }
}
