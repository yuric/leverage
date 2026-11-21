import Foundation
import LeverageKit

/// Runs one read, then reports its observation before returning the
/// request result. The clock starts before the first provider call.
struct UsageRead: Sendable {
    let api: any HelperAPI
    let settings: HelperSettings
    let timings: HelperTimings
    let http: ProviderHTTP
    let vault: any TokenVault
    let log: Log
    var readers: UsageReaders.Lookup = UsageReaders.reader(for:)
    var testedVersions: @Sendable (Provider) -> [String] = { $0.testedToolVersions }
    var now: @Sendable () -> Date = { Date() }

    private struct Observation: Sendable {
        var reading = UsageReading(state: .unavailable)
        var version: String?
        var failure: HelperCheckFailure?
    }

    private struct TimeExpired: Error {}

    func run(_ request: HelperRequest) async -> HelperRequestResult {
        var check = CheckRun(request: request, api: api, log: log)
        guard let credential = request.credentialID, let provider = request.params.provider,
              let kind = request.params.credentialKind else {
            return await check.fail(.readingTaken, .noAnswer)
        }
        let observedAt = now()
        await check.report(HelperCheckProgress(check: .readingTaken, state: .running))
        let observation: Observation
        do {
            observation = try await observe(provider, credentialID: credential, kind: kind)
        } catch is TimeExpired {
            observation = Observation(failure: .timedOut)
        } catch let error as ProviderHTTP.Failure {
            observation = Observation(failure: error.checkFailure)
        } catch {
            observation = Observation(failure: .unreachable)
        }

        check.toolVersion = observation.version
        guard !Task.isCancelled else { return check.result(.failed) }
        let reading = CredentialReading(
            credentialID: credential, observedAt: observedAt, state: observation.reading.state,
            toolVersion: observation.version, figures: observation.reading.figures, resets: observation.reading.resets)
        do {
            let result = try await api.reportReading(credentialID: credential, reading, key: IdempotencyKey())
            _ = try result.completedResult()
        } catch {
            log.warning("could not report a reading for credential \(credential.contractString)")
            return await check.fail(.readingTaken, observation.failure ?? .unreachable)
        }
        if let failure = observation.failure {
            return await check.fail(.readingTaken, failure)
        }
        await check.pass(.readingTaken)
        return check.result(.finished)
    }

    private func observe(_ provider: Provider, credentialID: UUID, kind: CredentialKind) async throws -> Observation {
        let clock = ContinuousClock()
        let deadline = clock.now + timings.readLimit
        return try await withThrowingTaskGroup(of: Observation.self) { group in
            group.addTask {
                try Task.checkCancellation()
                switch kind {
                case .apiToken:
                    return try await readToken(provider, credentialID: credentialID, deadline: deadline)
                case .login:
                    return try await readLogin(provider, credentialID: credentialID, deadline: deadline)
                }
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                throw TimeExpired()
            }
            defer { group.cancelAll() }
            guard let observation = try await group.next(), clock.now < deadline else { throw TimeExpired() }
            return observation
        }
    }

    private func readToken(
        _ provider: Provider, credentialID: UUID, deadline: ContinuousClock.Instant
    ) async throws -> Observation {
        let stored: ProviderToken?
        do {
            stored = try vault.read(credentialID: credentialID)
        } catch {
            return Observation(failure: TokenVaultFailure.checkFailure(for: error))
        }
        guard let token = stored else { return Observation(failure: .notSignedIn) }
        guard token.provider == provider else { return Observation(failure: .providerMismatch) }
        let response = try await http.get(token.provider, token: token.value, timeout: deadline - ContinuousClock.now)
        let reading = TokenReaders.read(provider: provider, status: response.status, headers: response.headers, body: response.body)
        return Observation(reading: reading, failure: reading.state == .unavailable ? .noAnswer : nil)
    }

    private func readLogin(
        _ provider: Provider, credentialID: UUID, deadline: ContinuousClock.Instant
    ) async throws -> Observation {
        let versions = testedVersions(provider)
        guard !versions.isEmpty, let reader = readers(provider),
              let entry = ProviderCatalog.entry(for: provider.rawValue) else {
            return Observation()
        }
        var toolTimings = timings
        toolTimings.commandLimit = min(timings.commandLimit, deadline - ContinuousClock.now)
        let locator = ToolLocator(settings: settings, timings: toolTimings)
        guard let tool = await locator.locate(entry) else { return Observation(failure: .notInstalled) }
        try Task.checkCancellation()
        let version = String(Redaction.redact(tool.version).prefix(64))
        var observation = Observation(version: version)
        guard VersionGate.accepts(tool.version, testedVersions: versions) else {
            return observation
        }

        let folder: URL?
        if entry.accountFolderVariable.value != nil {
            guard let existing = AccountFolders(supportFolder: settings.supportFolder).existing(for: credentialID) else {
                observation.reading = UsageReading(state: .signedOut)
                return observation
            }
            folder = existing
        } else {
            folder = nil
        }
        let environment = locator.toolEnvironment(entry, toolPath: tool.path, accountFolder: folder)
        let status = await SignInStatus.check(
            entry, toolPath: tool.path, environment: environment,
            timeLimit: min(timings.commandLimit, deadline - ContinuousClock.now))
        try Task.checkCancellation()
        if status == .signedOut { observation.reading = UsageReading(state: .signedOut) }
        guard status == .signedIn else { return observation }

        // Each reader starts in an empty folder, including when several
        // accounts are read at the same time.
        let work = settings.supportFolder.appendingPathComponent("reads", isDirectory: true)
            .appendingPathComponent(UUID().contractString, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: work) }
        observation.reading = try await reader.read(ReaderAccount(
            entry: entry, tool: tool, accountFolder: folder, environment: environment,
            workingDirectory: work, deadline: deadline))
        return observation
    }
}
