import Foundation
import LeverageKit

/// The three checks of a login, in order (L602, IN-23): the tool is
/// installed, the account is signed in, a test prompt gets an answer. Each
/// check's state is reported while it runs; the result goes back to the
/// request loop.
///
/// Add waits for the owner: for a missing tool to be installed (from the
/// pop-up, or by hand where leverage cannot install it, PV-5) and for the
/// sign-in in the provider's own window (PV-4), looking again on its own
/// for up to 10 minutes (CL-19). A failed add deletes the folder it made
/// (CL-18); the server deletes the row (IN-24).
///
/// Verify is the same checks with no waiting: a missing tool or a signed-out
/// account fails at once, no sign-in is opened, and the folder is kept.
///
/// Sign in again (plan HE-36) is milestone 2's sign-in wait followed by the
/// verify checks: a missing tool fails at once, a signed-out account opens
/// the provider's own sign-in and waits for it as Add does, and the
/// account's folder is kept whatever the result. A login whose folder is
/// gone gets a new, empty one to sign in to.
struct AddChecks: Sendable {
    /// Which of the three requests runs the checks.
    enum Mode: Sendable {
        case add, verify, signInAgain

        /// Waits for the owner to install a missing tool.
        var waitsForInstall: Bool { self == .add }
        /// Opens the provider's sign-in and waits for the owner.
        var waitsForSignIn: Bool { self != .verify }
    }

    let api: any HelperAPI
    let settings: HelperSettings
    let timings: HelperTimings
    let prober: any TestPrompting
    let log: Log
    var cleanup: CredentialCleanup? = nil
    var tokens: TokenChecks? = nil
    var facts = AccountFacts()

    var locator: ToolLocator { ToolLocator(settings: settings, timings: timings) }
    var folders: AccountFolders { AccountFolders(supportFolder: settings.supportFolder) }

    func add(_ request: HelperRequest) async -> HelperRequestResult {
        await run(request, mode: .add)
    }

    func verify(_ request: HelperRequest) async -> HelperRequestResult {
        await run(request, mode: .verify)
    }

    func signInAgain(_ request: HelperRequest) async -> HelperRequestResult {
        await run(request, mode: .signInAgain)
    }

    private static let loginChecks: [HelperCheck] = [.toolInstalled, .signedIn, .testPrompt]

    private func run(_ request: HelperRequest, mode: Mode) async -> HelperRequestResult {
        var run = CheckRun(request: request, api: api, log: log)
        guard let credential = request.credentialID, request.params.credentialKind != .apiToken,
              let provider = request.params.provider,
              let entry = ProviderCatalog.entry(for: provider.rawValue)
        else {
            // Tokens arrive in milestone 6; the server refuses them at Add.
            return await run.fail(.toolInstalled, .notInstalled)
        }
        for check in Self.loginChecks {
            await run.report(HelperCheckProgress(check: check, state: .waiting))
        }

        // The account's own folder, for a provider that keeps one.
        var folder: URL?
        if entry.accountFolderVariable.value != nil {
            folder = folders.existing(for: credential)
            if mode == .verify, folder == nil { return await run.fail(.signedIn, .notSignedIn) }
            if mode == .add || folder == nil {
                do {
                    folder = try folders.createFresh(for: credential)
                } catch {
                    log.error("could not make the folder of credential \(credential.contractString)")
                    return await run.fail(.signedIn, .rejected)
                }
            }
        }
        let result = await checks(entry, folder: folder, mode: mode, run: &run)
        if result.outcome == .failed, mode == .add {
            folders.remove(for: credential)
        }
        return result
    }

    private func checks(
        _ entry: ProviderEntry, folder: URL?, mode: Mode, run: inout CheckRun
    ) async -> HelperRequestResult {
        // 1. Installed.
        await run.report(HelperCheckProgress(check: .toolInstalled, state: .running))
        var found = await locator.locate(entry)
        if found == nil {
            let offer = Self.offer(for: entry)
            if !mode.waitsForInstall { return await run.fail(.toolInstalled, .notInstalled, install: offer) }
            await run.report(HelperCheckProgress(check: .toolInstalled, state: .waitingForInstall, install: offer))
            let locator = self.locator
            let appeared = await Waiting.until(every: timings.lookEvery, atMost: timings.waitAtMost) {
                await locator.locate(entry) != nil
            }
            found = appeared ? await locator.locate(entry) : nil
            guard found != nil else { return await run.fail(.toolInstalled, .notInstalled, install: offer) }
        }
        guard let tool = found else { return await run.fail(.toolInstalled, .notInstalled) }
        run.toolVersion = tool.version
        await run.pass(.toolInstalled)

        // 2. Signed in, to this account's folder or the Mac's one sign-in.
        await run.report(HelperCheckProgress(check: .signedIn, state: .running))
        let status = ToolStatus(locator: locator, prober: prober, settings: settings)
        let look: @Sendable () async -> Bool = { await status.isSignedIn(entry, tool: tool, accountFolder: folder) }
        if await !look() {
            if !mode.waitsForSignIn { return await run.fail(.signedIn, .notSignedIn) }
            await run.report(HelperCheckProgress(check: .signedIn, state: .waitingForSignIn))
            let window = SignInWindow(locator: locator, timings: timings)
            guard await window.waitForSignIn(entry, tool: tool, accountFolder: folder, look: look) else {
                return await run.fail(.signedIn, Task.isCancelled ? .timedOut : .notSignedIn)
            }
        }
        await run.pass(.signedIn)

        // 3. Answering. Where the sign-in check was a test prompt, it was
        // answered already.
        await run.report(HelperCheckProgress(check: .testPrompt, state: .running))
        if case .testPrompt = entry.status.value.reading {
            // Answered by the sign-in check above.
        } else if await !prober.answers(entry, tool: tool, accountFolder: folder, settings: settings) {
            return await run.fail(.testPrompt, .noAnswer)
        }
        await run.pass(.testPrompt)
        return run.result(.finished)
    }

    /// What would be installed and from where, or that leverage cannot
    /// install it (PV-5).
    static func offer(for entry: ProviderEntry) -> InstallOffer {
        guard let installer = entry.installer.value else {
            return InstallOffer(installable: false, what: entry.toolDisplayName, sourceURL: nil)
        }
        return InstallOffer(installable: true, what: entry.toolDisplayName, sourceURL: installer.url)
    }
}

/// One request's checks so far and its progress reports.
struct CheckRun {
    let request: HelperRequest
    let api: any HelperAPI
    let log: Log
    var checks: [HelperCheckResult] = []
    var toolVersion: String?

    init(request: HelperRequest, api: any HelperAPI, log: Log) {
        self.request = request
        self.api = api
        self.log = log
    }

    /// Reports one check's state, with a key of its own; a failed report is
    /// logged and the checks go on (the result is what counts).
    func report(_ progress: HelperCheckProgress) async {
        do {
            _ = try await api.reportRequestProgress(requestID: request.id, progress, key: IdempotencyKey())
        } catch {
            log.warning("could not report \(progress.check.rawValue) of request \(request.id.contractString)")
        }
    }

    mutating func pass(_ check: HelperCheck) async {
        await report(HelperCheckProgress(check: check, state: .passed))
        checks.append(HelperCheckResult(check: check, passed: true))
    }

    mutating func fail(
        _ check: HelperCheck, _ failure: HelperCheckFailure, install: InstallOffer? = nil
    ) async -> HelperRequestResult {
        await report(HelperCheckProgress(check: check, state: .failed, failure: failure, install: install))
        checks.append(HelperCheckResult(check: check, passed: false, failure: failure))
        return result(.failed)
    }

    func result(_ outcome: HelperRequestOutcome) -> HelperRequestResult {
        // IN-25: no plan and no email in this milestone.
        HelperRequestResult(outcome: outcome, checks: checks, toolVersion: toolVersion, plan: nil, accountEmail: nil)
    }
}
