import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

@Suite("Local helper channel", .timeLimit(.minutes(Patience.minutes(1))))
struct LocalChannelTests {
    @Test func tokenAndForgetSurviveFramingAndEOF() async throws {
        let rig = try HelperRig()
        let clock = Locked(ContinuousClock.now)
        let pending = PendingTokens(now: { clock.value }, sleep: { deadline in
            // Expire an absent take immediately without expiring a newly
            // delivered token during this test.
            if deadline - clock.value <= .seconds(5) { clock.value = deadline }
            else { try await Task.sleep(for: Patience.scaled(.seconds(60))) }
        })
        let vault = MemoryTokenVault()
        let log = CapturedLog()
        let runtime = HelperRuntime(
            api: rig.api, settings: rig.settings, timings: fastTimings, log: log.log,
            pending: pending, vault: vault)
        let kept = UUID()
        let forgotten = UUID()
        let token = "LVRG-TOKEN-000000000701"
        try vault.store(token, credentialID: forgotten)
        let pipe = Pipe()
        var bytes = try LocalHelperMessage.token(credentialID: kept, token: token).encodeLine()
        bytes.append(Data("\nbroken with \(token)\n".utf8))
        bytes.append(try LocalHelperMessage.forget(credentialID: forgotten).encodeLine())
        bytes.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()

        let loop = Task { await runtime.run() }
        defer { loop.cancel() }
        await LocalChannel(cleanup: runtime.cleanup, log: log.log).run(input: pipe.fileHandleForReading)

        // EOF ends the channel, while the helper can still take work.
        let request = helperRequest(.verify, credential: forgotten, params: .init(provider: .openrouter, credentialKind: .apiToken))
        let queue = RequestLoopTests.Queue([.success(request)])
        rig.api.script { $0.next = { _ in try await queue.next() } }
        #expect(await eventually { rig.calls(.reportRequestResult).count == 1 })
        await runtime.shutdown()
        #expect(await loop.value == HelperExitCode.stopped)

        // A second line cannot resurrect the token that was forgotten.
        let later = Pipe()
        var afterForget = try LocalHelperMessage.token(credentialID: forgotten, token: token).encodeLine()
        afterForget.append(0x0A)
        try later.fileHandleForWriting.write(contentsOf: afterForget)
        try later.fileHandleForWriting.close()
        await LocalChannel(cleanup: runtime.cleanup, log: log.log).run(input: later.fileHandleForReading)

        let delivered = await pending.take(credentialID: kept) == token
        let ignored = await pending.take(credentialID: forgotten) == nil
        #expect(ignored)
        #expect(delivered)
        let erased = try vault.read(credentialID: forgotten) == nil
        #expect(erased)
        #expect(log.text.components(separatedBy: "invalid local message").count == 2)
        let scrubbed = !log.text.contains(token) && !log.text.contains("broken with")
        #expect(scrubbed)
    }
}
