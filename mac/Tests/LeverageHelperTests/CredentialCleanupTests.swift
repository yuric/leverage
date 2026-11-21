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

    @Test("confirmed removal cleans the earlier private account folder and acknowledges completion")
    func removesLegacyFolder() async throws {
        let rig = try HelperRig()
        let id = UUID()
        let other = UUID()
        let files = FileManager.default
        let account = try rig.folders.createFresh(for: id)
        let sibling = try rig.folders.createFresh(for: other)
        try files.createSymbolicLink(at: account.appendingPathComponent("linked"), withDestinationURL: sibling)
        let queue = rig.support.appendingPathComponent("pending-removals")
        try files.createDirectory(at: queue, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let receipt = queue.appendingPathComponent(id.contractString)
        try Data().write(to: receipt)
        let cleanup = CredentialCleanup(folders: rig.folders, pending: PendingTokens(), vault: MemoryTokenVault(),
                                        requests: RunningRequests(), log: quietLog)
        await cleanup.forget(id)
        await cleanup.forget(id)
        #expect(!files.fileExists(atPath: account.path))
        #expect(!files.fileExists(atPath: receipt.path))
        #expect(files.fileExists(atPath: sibling.path))
    }

    @Test("confirmed removal preserves a linked account, linked root, mismatched marker and shared legacy folder")
    func preservesUnownedDirectories() async throws {
        for kind in ["account link", "root link", "wrong marker", "shared folder", "shared root"] {
            let rig = try HelperRig()
            let id = UUID()
            let files = FileManager.default
            let account = try rig.folders.createFresh(for: id)
            let queue = rig.support.appendingPathComponent("pending-removals")
            try files.createDirectory(at: queue, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data().write(to: queue.appendingPathComponent(id.contractString))
            var target = account
            switch kind {
            case "account link":
                target = rig.folder.url.appendingPathComponent("outside")
                try files.moveItem(at: account, to: target)
                try files.createSymbolicLink(at: account, withDestinationURL: target)
            case "root link":
                let outside = rig.folder.url.appendingPathComponent("outside")
                target = outside.appendingPathComponent(id.contractString)
                try files.moveItem(at: rig.folders.root, to: outside)
                try files.createSymbolicLink(at: rig.folders.root, withDestinationURL: outside)
            case "wrong marker":
                try Data("another folder".utf8).write(to: target.appendingPathComponent(".leverage-owned"))
            case "shared folder":
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: account.path)
            default:
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folders.root.path)
            }
            let cleanup = CredentialCleanup(folders: rig.folders, pending: PendingTokens(), vault: MemoryTokenVault(),
                                            requests: RunningRequests(), log: quietLog)
            await cleanup.forget(id)
            #expect(files.fileExists(atPath: target.path), "\(kind)")
        }
    }

    @Test("forget lets an active sign-in child finish with its account folder still present")
    func waitsForSignInChild() async throws {
        let rig = try HelperRig()
        let entry = try #require(ProviderCatalog.entry(for: "claude"))
        let credential = UUID()
        let running = RunningRequests()
        let cleanup = CredentialCleanup(folders: rig.folders, pending: PendingTokens(), vault: MemoryTokenVault(),
                                        requests: running, log: quietLog)
        let account = try cleanup.createFolder(for: credential)
        let ready = rig.folder.url.appendingPathComponent("sign-in-ready")
        let finished = rig.folder.url.appendingPathComponent("sign-in-finished")
        let program = rig.tools.file("sign-in-cleanup")
        try Data("""
        #!/usr/bin/env python3
        import os
        from pathlib import Path
        import signal
        import time

        root = Path(os.environ["TMPDIR"])
        account = Path(os.environ["CLAUDE_CONFIG_DIR"])
        parent = os.getppid()
        stopped = False

        def stop(*_):
            global stopped
            stopped = True

        signal.signal(signal.SIGTERM, stop)
        ready = root / "sign-in-ready"
        pending = ready.with_suffix(".tmp")
        pending.write_text(str(os.getpid()))
        pending.replace(ready)
        deadline = time.monotonic() + \(Patience.seconds(45))
        while not stopped and os.getppid() == parent and time.monotonic() < deadline:
            time.sleep(0.01)

        if stopped:
            # A provider may finish cleanup during its grace period. A
            # removed folder ends the wait early so the race is observable.
            deadline = time.monotonic() + 0.5
            while account.is_dir() and time.monotonic() < deadline:
                time.sleep(0.01)
            (root / "sign-in-finished").write_text("present" if account.is_dir() else "removed")
        """.utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)

        let window = SignInWindow(locator: ToolLocator(settings: rig.settings, timings: fastTimings),
                                  timings: fastTimings)
        let request = loginRequest(credential, kind: .openSignIn)
        running.start(request) {
            _ = await window.waitForSignIn(entry, tool: LocatedTool(path: program.path, version: "stand-in"),
                                          accountFolder: account) { false }
        }
        let started = await eventually { FileManager.default.fileExists(atPath: ready.path) }
        await cleanup.forget(credential)
        try #require(started)
        let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8)))
        #expect(!isAlive(pid), "forget waits for the sign-in child to be reaped")
        #expect(await eventually(within: 5) { !isAlive(pid) })
        #expect(try String(contentsOf: finished, encoding: .utf8) == "present")
        #expect(rig.folders.existing(for: credential) == nil)
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
