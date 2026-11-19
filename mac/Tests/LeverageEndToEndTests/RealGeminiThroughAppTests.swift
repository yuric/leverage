import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

/// The developer check with the real Antigravity (the managing agent's
/// override 8), run only by scripts/real_gemini_through_app.sh, which sets
/// LEVERAGE_E2E=1 and LEVERAGE_REAL_PROVIDER=gemini. It never runs in CI and
/// no agent runs it but the managing agent.
///
/// The path is the end-to-end run's: the real API in its containers, the real
/// helper, the real runner, with the real `agy` found where the helper looks
/// (the Mac's `~/.local/bin`, Homebrew's folders, then `PATH`). Antigravity
/// keeps one sign-in for the whole Mac and it is already signed in, so the
/// Gemini login is added through Add credential with no sign-in by anyone.
///
/// The builder is a seat the app runs on that login. The reviewer cannot be:
/// the runner offers no Gemini reviewer (CL-8, WP11's step 0: agy's plan mode
/// did not answer a plain prompt), and a Claude or Codex login added through
/// Add credential would need a person to sign in. So the reviewer is a seat
/// that connects on its own, run here by the real runner with the stand-in
/// Codex, which passes every review. What this proves is the real tool as a
/// builder through Add credential, the helper and the runner; nothing about
/// a real reviewer. It forces no failed review.
@Suite(
    "Real Gemini through the app",
    .enabled(if: ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "1"
        && ProcessInfo.processInfo.environment[EnvironmentKeys.realProvider] == "gemini"
        && ProcessInfo.processInfo.environment["CI"] == nil))
struct RealGeminiThroughAppTests {
    @Test("a Gemini builder added through Add credential takes a small task to Done")
    func realGemini() async throws {
        let folder = try TestFolder("real-gemini")
        let tools = try StandIns.copy(into: folder.url)
        let work = try folder.folder("work")
        let owner = try await EndToEnd.owner()
        try folder.record(secrets: [EndToEnd.ownerPassword, owner.transport.token ?? ""].filter { !$0.isEmpty })

        guard let helperToken = try await owner.issueHelperToken(
            name: "Real Gemini check", idempotencyKey: IdempotencyKey().value) else {
            throw EndToEndFailure("issue_helper_token answered no token")
        }
        try folder.record(secrets: [helperToken])
        let follower = try await EventFollower.fromNow(owner: owner)
        let helper = try RunningHelper(token: helperToken, folder: folder, tools: nil)
        var reviewerRun: RunningSubprocess?

        try await withCleanup {
            let gemini = try await owner.addLogin(.gemini, name: "Gemini (real check)", deadline: 600)
            let builder = try await owner.connect("Gemini builder", role: .builder, login: gemini)
            try await owner.waitUntilRunning([builder])

            // The reviewer: a seat that connects on its own, its token shown
            // once and given only to the runner's environment.
            let connected = try await owner.connectSeat(
                ConnectSeatRequest(name: "Stand-in reviewer", role: .reviewer, provider: .codex),
                key: IdempotencyKey())
            guard case .shown(let seat)? = try connected.completedResult(), let token = seat.seatToken else {
                throw EndToEndFailure("connect_seat showed no token for the reviewer")
            }
            try folder.record(secrets: [token])
            let account = try folder.folder("reviewer-account")
            try tools.signIn("codex", accountFolder: account)
            reviewerRun = try Subprocess.start(SubprocessRequest(
                executable: try EndToEnd.program("LeverageRunner").path,
                arguments: [],
                environment: [
                    EnvironmentKeys.path: "/usr/bin:/bin",
                    EnvironmentKeys.home: try folder.folder("reviewer-home").path,
                    EnvironmentKeys.lang: "en_US.UTF-8",
                    EnvironmentKeys.apiURL: EndToEnd.apiURL.absoluteString,
                    EnvironmentKeys.seatToken: token,
                    EnvironmentKeys.seatRole: SeatRole.reviewer.rawValue,
                    EnvironmentKeys.provider: Provider.codex.rawValue,
                    EnvironmentKeys.toolPath: tools.tool("codex").path,
                    EnvironmentKeys.settingsDir: account.path,
                    EnvironmentKeys.toolDir: tools.bin.path,
                    EnvironmentKeys.supportDir: folder.support.path,
                    EnvironmentKeys.workRoot: try folder.folder("reviewer-work").path,
                ],
                gracePeriod: .seconds(20)))

            let task = try await owner.addReadyTask(
                title: "Real Gemini check",
                criteria: ["The folder holds a file named hello.txt that contains the word ready."],
                folder: work).task
            _ = try await follower.wait(
                for: "task.done", deadline: 900,
                failing: { $0.taskID == task && $0.type == .taskCancelled },
                where: { $0.taskID == task && $0.type == .taskDone })
            let events = await follower.events(of: task)
            #expect(events.filter { $0.type == .taskSubmitted }.allSatisfy { $0.actorID == builder })
            #expect(events.contains { $0.type == .reviewPassed && $0.actorID == seat.seatID })
            try await owner.stopAndWait(seat: builder)
        } cleanup: {
            if let reviewerRun {
                reviewerRun.stop()
                let result = await reviewerRun.wait()
                try? (result.standardOutput + result.standardError)
                    .write(to: folder.logs.appendingPathComponent("reviewer-runner.log"))
            }
            await helper.stop()
        }
    }
}
