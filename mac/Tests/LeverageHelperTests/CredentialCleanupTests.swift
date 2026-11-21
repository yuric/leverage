import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

@Suite("Credential cleanup", .timeLimit(.minutes(Patience.minutes(1))))
struct CredentialCleanupTests {
    @Test("forget deletes the token and a folder the helper made only")
    func deletesOnlyOwnedLocalState() async throws {
        let rig = try HelperRig()
        let vault = MemoryTokenVault()
        let credential = UUID()
        let other = UUID()
        let log = CapturedLog()
        let cleanup = CredentialCleanup(folders: rig.folders, pending: PendingTokens(), vault: vault,
                                        requests: RunningRequests(), log: log.log)
        try vault.store("LVRG-TOKEN-000000000706", credentialID: credential)
        let owned = try cleanup.createFolder(for: credential)
        let external = try rig.folders.createFresh(for: other)

        // The folder was made by an earlier helper instance.
        let restarted = CredentialCleanup(folders: rig.folders, pending: PendingTokens(), vault: vault,
                                          requests: RunningRequests(), log: log.log)
        await restarted.forget(UUID())
        await restarted.forget(other)
        await restarted.forget(credential)

        let erased = try vault.read(credentialID: credential) == nil
        #expect(erased)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test("forget stops an active request and later requests cannot start tools or recreate folders")
    func cancelsActiveAndRejectsLaterRequests() async throws {
        let rig = try HelperRig()
        _ = UsageReadTests.recordReadings(rig)
        let credential = UUID()
        let child = Locked<ReadProcess?>(nil)
        let entry = try #require(ProviderCatalog.entry(for: "claude"))
        let version = try #require(await ToolLocator(settings: rig.settings, timings: fastTimings).locate(entry)).version
        var timings = fastTimings
        timings.readLimit = Patience.scaled(.seconds(45))
        let runtime = HelperRuntime(api: rig.api, settings: rig.settings, timings: timings, log: quietLog,
                                    usageReaders: { _ in HungUsageReader(child: child) }, testedVersions: { _ in [version] })
        let folder = try runtime.cleanup.createFolder(for: credential)
        try rig.tools.signIn("claude", accountFolder: folder)
        let active = loginRequest(credential)
        let queue = RequestLoopTests.Queue([.success(active)])
        rig.api.script { $0.next = { _ in try await queue.next() } }
        let loop = Task { await runtime.run() }
        defer { loop.cancel() }
        // A baseline that reports a result without starting a child exits this wait early.
        let settled = await eventually {
            child.value != nil || !rig.calls(.reportRequestResult).isEmpty
        }
        try #require(settled)
        let started = try #require(child.value)
        defer { started.process.stop() }
        await runtime.cleanup.forget(credential)
        #expect(!isAlive(started.process.processID))
        #expect(await eventually(within: 5) { !isAlive(started.descendant) })
        #expect(rig.calls(.reportRequestResult).isEmpty)

        let toolCalls = try rig.tools.calls().count
        let verify = loginRequest(credential, kind: .verify)
        let signIn = loginRequest(credential, kind: .openSignIn)
        let read = loginRequest(credential)
        let later = RequestLoopTests.Queue([.success(verify), .success(signIn), .success(read)])
        let reports = Locked<[UUID: HelperRequestResult]>([:])
        rig.api.script {
            $0.next = { _ in try await later.next() }
            $0.reportRequestResult = { id, result, key in
                reports.update { $0[id] = result }
                return .completed(.object([:]), key: key.value, command: .reportRequestResult)
            }
        }
        #expect(await eventually { reports.value.count == 3 })
        for (request, check) in [(verify, HelperCheck.signedIn), (signIn, .signedIn), (read, .readingTaken)] {
            let result = reports.value[request.id]
            #expect(result?.checks == [HelperCheckResult(check: check, passed: false, failure: .notSignedIn)])
        }
        #expect(try rig.tools.calls().count == toolCalls)
        #expect(rig.folders.existing(for: credential) == nil)
        await runtime.shutdown()
        _ = await loop.value
    }
}
