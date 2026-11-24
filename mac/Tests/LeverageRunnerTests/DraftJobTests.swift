import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// One contract-draft job (milestone 4 plan section 2.2, RD-37): the prompt,
// one tool run in check mode in a new empty folder, and the contract the
// result sends, with the stored values the planner may not change.
@Suite("Draft job", .timeLimit(.minutes(Patience.minutes(2))))
struct DraftJobTests {
    static func contract(_ end: JobRunEnd) -> CompleteContractRequest? {
        guard case .result(let request) = end, case .contractDraft(let contract) = request.result else { return nil }
        return contract
    }

    @Test("the stand-in planner's draft becomes the contract, with the work reference, rank and cap unchanged")
    func standIn() async throws {
        let drivers = try DriverTests.Setup()
        let harness = try Harness()
        let tool = DriverTests.cases[1]  // codex
        try drivers.signIn(tool)
        let driver = try drivers.driver(tool, model: nil, effort: nil)
        let end = try await DraftJob(context: harness.context(driver: driver))
            .run(JobFixture.draftClaim(), input: JobFixture.draftInput())
        let contract = try #require(Self.contract(end))
        #expect(contract.title == JobFixture.title)
        #expect(contract.details == "\(JobFixture.details)\n\nWritten by the stand-in planner.")
        #expect(contract.criteria == [
            CriterionInput(text: "The requested page exists.", kind: .build),
            CriterionInput(text: "The page includes the requested information.", kind: .build),
            CriterionInput(text: DraftParser.reviewCriterion, kind: .review),
        ])
        #expect(contract.workReference == "/Users/example/sites/alpaca")
        #expect(contract.minimumStrengthRank == 2)
        #expect(contract.budgetCap == Decimal(string: "12.5"))
        #expect(contract.actions.isEmpty)
        // Run read-only, in check mode, never in the task's folder.
        let call = try drivers.lastCall()
        #expect(call.argv.contains("read-only"))
        #expect(!call.argv.contains("workspace-write"))
        #expect(!call.cwd.hasPrefix("/Users/example/sites/alpaca"))
        if case .result(let request) = end { #expect(request.tokens == 240 && request.spend == 0) }
    }

    @Test("the prompt holds the criteria the task already has, in a quote block (RD-37)")
    func prompt() async throws {
        let harness = try Harness()
        let driver = ScriptedDriver { _, _ in .answer("No draft.", tokens: 1) }
        _ = try await DraftJob(context: harness.context(driver: driver))
            .run(JobFixture.draftClaim(), input: JobFixture.draftInput())
        let run = try #require(driver.runs.first)
        #expect(run.purpose == .check)
        let nonce = try #require(JobFixture.nonce(of: run.prompt))
        let (blocks, _) = try JobPromptsTests.blocks(run.prompt, nonce: nonce)
        #expect(blocks.first { $0.0 == "criteria" }?.1.contains("The walrus discount is named.") == true)
    }

    @Test("an answer with no draft sends nothing", arguments: [
        "I cannot write this contract.",
        "LEVERAGE-DRAFT-@-BEGIN\n{\"details\": null, \"criteria\": []}\nLEVERAGE-DRAFT-@-END",
        "LEVERAGE-DRAFT-@-BEGIN\n{not json}\nLEVERAGE-DRAFT-@-END",
    ])
    func noDraft(answer: String) async throws {
        let harness = try Harness()
        let state = RunnerState()
        let driver = ScriptedDriver { prompt, _ in
            .answer(answer.replacingOccurrences(of: "@", with: JobFixture.nonce(of: prompt) ?? ""), tokens: 1)
        }
        let end = try await DraftJob(context: harness.context(driver: driver, state: state))
            .run(JobFixture.draftClaim(), input: JobFixture.draftInput())
        #expect(end == .noResult)
        #expect(state.consecutiveToolFailures == 1)
    }

    @Test("a draft's tool run ends 10 seconds before the job's run is due, and its folder is removed")
    func limitAndFolder() async throws {
        let harness = try Harness()
        let clock = TestClock()
        let seen = Seen()
        let driver = ScriptedDriver(request: { request in
            seen.add(request.folder, empty: (try? FileManager.default.contentsOfDirectory(atPath: request.folder.path))
                .map(\.isEmpty) ?? false)
            return .answer("No draft.", tokens: 1)
        })
        _ = try await DraftJob(context: harness.context(driver: driver, timing: clock.timing()))
            .run(JobFixture.draftClaim(runDueAt: clock.now.addingTimeInterval(120)), input: JobFixture.draftInput())
        #expect(driver.runs.map(\.timeLimitSeconds) == [110])
        #expect(seen.allEmpty && seen.folders.count == 1)
        #expect(seen.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
