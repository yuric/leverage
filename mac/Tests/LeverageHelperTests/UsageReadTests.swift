import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Usage reads", .timeLimit(.minutes(Patience.minutes(1))))
struct UsageReadTests {
    static func recordReadings(_ rig: HelperRig) -> Locked<[CredentialReading]> {
        let readings = Locked<[CredentialReading]>([])
        rig.api.script {
            $0.reportReading = { _, reading, key in
                readings.update { $0.append(reading) }
                return .completed(.object([:]), key: key.value, command: .reportReading)
            }
        }
        return readings
    }

    @Test("a token reading is sent before the loop reports a passed result")
    func storedTokenReportedBeforeResult() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let vault = MemoryTokenVault()
        let credential = UUID()
        try vault.store(ProviderToken(provider: .openaiApi, value: "LVRG-TOKEN-000000000704"), credentialID: credential)
        let stub = StubURLProtocol.session(host: "api.openai.com", answer: .init(status: 200, json: "{\"object\":\"list\",\"data\":[]}"))
        defer { stub.invalidateAndCancel() }
        let runtime = HelperRuntime(
            api: rig.api, settings: rig.settings, timings: fastTimings, log: quietLog, vault: vault,
            http: try ProviderHTTP(executableURL: URL(fileURLWithPath: "/test/LeverageHelper"), environment: [:],
                                   protocolClasses: [StubURLProtocol.self]))
        let queue = RequestLoopTests.Queue([.success(tokenRequest(credential))])
        let resultWasPassed = Locked(false)
        rig.api.script {
            $0.next = { _ in try await queue.next() }
            $0.reportRequestResult = { _, result, key in
                resultWasPassed.value = result.checks == [HelperCheckResult(check: .readingTaken, passed: true)]
                return .completed(.object([:]), key: key.value, command: .reportRequestResult)
            }
        }
        let loop = Task { await runtime.run() }
        defer { loop.cancel() }
        #expect(await eventually { rig.calls(.reportRequestResult).count == 1 })
        await runtime.shutdown()
        _ = await loop.value

        #expect(readings.value.first?.state == .ok)
        #expect(resultWasPassed.value)
        let reports = rig.api.calls.map(\.operation).filter { [.reportReading, .reportRequestResult].contains($0) }
        #expect(reports == [.reportReading, .reportRequestResult])
        #expect(!rig.everythingSent().contains("LVRG-TOKEN-"))
    }

    @Test("a failed report to the workspace does not say the provider was unreachable")
    func failedWorkspaceReport() async throws {
        let rig = try HelperRig()
        rig.api.script { $0.reportReading = { _, _, _ in throw LeverageClientError.invalidBody } }
        let read = UsageRead(api: rig.api, settings: rig.settings, timings: fastTimings, http: ProviderHTTP(),
                             vault: MemoryTokenVault(), log: quietLog)
        let result = await read.run(loginRequest(UUID(), provider: .gemini))
        #expect(result.checks.last?.failure == .noAnswer)
    }

    @Test("absent token reports unavailable without contacting a provider")
    func missingToken() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let read = UsageRead(api: rig.api, settings: rig.settings, timings: fastTimings, http: ProviderHTTP(),
                             vault: MemoryTokenVault(), log: quietLog)
        _ = await read.run(tokenRequest(UUID()))
        #expect(readings.value.first?.state == .unavailable)
    }

    @Test("with no login reader it reports unavailable without starting a provider tool")
    func missingLoginReader() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let read = UsageRead(api: rig.api, settings: rig.settings, timings: fastTimings, http: ProviderHTTP(),
                             vault: MemoryTokenVault(), log: quietLog)
        _ = await read.run(loginRequest(UUID(), provider: .gemini))
        #expect(readings.value.first?.state == .unavailable)
        #expect(try rig.tools.calls().isEmpty)
    }

    @Test("a login reader without a tested version does not start the tool")
    func noTestedVersion() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let read = UsageRead(
            api: rig.api, settings: rig.settings, timings: fastTimings, http: ProviderHTTP(),
            vault: MemoryTokenVault(), log: quietLog, testedVersions: { _ in [] })

        _ = await read.run(loginRequest(UUID(), provider: .codex))
        #expect(readings.value.first?.state == .unavailable)
        #expect(readings.value.first?.toolVersion == nil)
        #expect(try rig.tools.calls().isEmpty)
    }

    @Test("an unknown version reports the version while running only the version command")
    func versionGate() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let started = Locked(false)
        var timings = fastTimings
        timings.readLimit = Patience.scaled(.seconds(30))
        let read = UsageRead(
            api: rig.api, settings: rig.settings, timings: timings, http: ProviderHTTP(), vault: MemoryTokenVault(),
            log: quietLog, readers: { _ in ProbeReader(started: started) }, testedVersions: { _ in ["9876.5432.1098"] })

        _ = await read.run(loginRequest(UUID()))
        #expect(readings.value.first?.state == .unavailable)
        #expect(readings.value.first?.toolVersion?.isEmpty == false)
        #expect(try rig.tools.calls().map(\.argv) == [["--version"]])
        #expect(!started.value)
    }

    @Test("login read timeout reports unavailable and ends the child")
    func loginTimeout() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let credential = UUID()
        let folder = try rig.folders.createFresh(for: credential)
        try rig.tools.signIn("claude", accountFolder: folder)
        let entry = try #require(ProviderCatalog.entry(for: "claude"))
        let version = try #require(await ToolLocator(settings: rig.settings, timings: fastTimings).locate(entry)).version
        var timings = fastTimings
        // The limit has to outlast the hung reader's start on a loaded Mac,
        // or the read times out before there is a child to end. What the
        // test checks is the end of the child, not the limit's length.
        timings.readLimit = Patience.scaled(.seconds(10))
        let child = Locked<ReadProcess?>(nil)
        let read = UsageRead(
            api: rig.api, settings: rig.settings, timings: timings, http: ProviderHTTP(), vault: MemoryTokenVault(),
            log: quietLog, readers: { _ in HungUsageReader(child: child) }, testedVersions: { _ in [version] })

        let result = await read.run(loginRequest(credential))
        #expect(readings.value.first?.state == .unavailable)
        #expect(result.checks == [HelperCheckResult(check: .readingTaken, passed: false, failure: .timedOut)])
        let started = try #require(child.value)
        #expect(!isAlive(started.process.processID))
        #expect(await eventually { !isAlive(started.descendant) })
        #expect((await started.process.wait()).endedBy == .stop)
    }

    @Test("an unanswered token request reports unavailable and a timed out result")
    func tokenTimeout() async throws {
        let rig = try HelperRig()
        let readings = Self.recordReadings(rig)
        let vault = MemoryTokenVault()
        let credential = UUID()
        var timings = fastTimings
        timings.readLimit = .seconds(2)
        try vault.store(ProviderToken(provider: .openaiApi, value: "LVRG-TOKEN-000000000705"), credentialID: credential)
        let read = UsageRead(
            api: rig.api, settings: rig.settings, timings: timings,
            http: try ProviderHTTP(executableURL: URL(fileURLWithPath: "/test/LeverageHelper"), environment: [:],
                                   protocolClasses: [NeverAnswersProtocol.self]),
            vault: vault, log: quietLog)

        let result = await read.run(tokenRequest(credential))
        #expect(readings.value.first?.state == .unavailable)
        #expect(result.outcome == .failed)
        #expect(result.checks == [HelperCheckResult(check: .readingTaken, passed: false, failure: .timedOut)])
    }

    private func tokenRequest(_ credential: UUID) -> HelperRequest {
        helperRequest(.readUsage, credential: credential, params: .init(provider: .openaiApi, credentialKind: .apiToken))
    }

    private struct ProbeReader: UsageReader {
        let started: Locked<Bool>
        func read(_ account: ReaderAccount) async throws -> UsageReading {
            started.value = true
            return UsageReading(state: .ok)
        }
    }

    private final class NeverAnswersProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }
}

func loginRequest(_ credential: UUID, provider: Provider = .claude, kind: HelperRequestKind = .readUsage) -> HelperRequest {
    helperRequest(kind, credential: credential, params: .init(provider: provider, credentialKind: .login))
}

struct ReadProcess: Sendable {
    let process: RunningSubprocess
    let descendant: Int32
}

struct HungUsageReader: UsageReader {
    let child: Locked<ReadProcess?>

    func read(_ account: ReaderAccount) async throws -> UsageReading {
        // The descendant also exits if the test process is lost.
        let script = """
            (while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done) &
            child=$!
            trap 'wait "$child"; exit 0' TERM
            printf '%s\\n' "$child"
            wait "$child"
            """
        let process = try Subprocess.startSession(.init(
            executable: "/bin/sh", arguments: ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier)],
            environment: [:], gracePeriod: .seconds(1)))
        return try await withTaskCancellationHandler {
            guard let line = await process.readLine(), let pid = Int32(String(decoding: line, as: UTF8.self)), pid > 1 else {
                process.stop()
                _ = await process.wait()
                throw CocoaError(.fileReadUnknown)
            }
            child.value = ReadProcess(process: process, descendant: pid)
            _ = await process.wait()
            return UsageReading(state: .unavailable)
        } onCancel: {
            process.stop()
        }
    }
}
