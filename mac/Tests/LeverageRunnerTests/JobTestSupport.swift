import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// What the job tests share (milestone 4): made-up check and draft material,
// claims, a clock a test moves itself, and a flow context over a fake API.

enum JobFixture {
    /// Task text, each piece with a word of its own, so a test can find
    /// every piece in a prompt.
    static let title = "Refresh the alpaca pricing page"
    static let goal = "The page shows the alpaca prices of this year."
    static let details = "Take the figures from the llama sheet."
    static let builtCriterion = "The copy names the walrus discount."
    static let reviewText = "An independent reviewer agrees."
    static let handoffNote = "Done; the narwhal folder holds the copy."
    static let evidence = "pangolin.txt in the work folder"
    static let roleFile = "You are the orchestrator. You judge task text against a rule."
    static let instruction = "Every task names the page it changes and the figures it uses."

    static func checkMaterial(mayAnswerNotApplicable: Bool = false, quoted: [QuotedText]? = nil) -> CheckMaterial {
        CheckMaterial(
            roleFile: roleFile, instruction: instruction, moment: "before work is submitted",
            mayAnswerNotApplicable: mayAnswerNotApplicable,
            contract: CheckContract(
                title: title, goal: goal, details: details,
                criteria: [
                    .init(text: builtCriterion, kind: .build, state: .passed),
                    .init(text: reviewText, kind: .review, state: .open),
                ]),
            quoted: quoted ?? [
                QuotedText(label: .handoffNote, text: handoffNote),
                QuotedText(label: .evidence, text: evidence),
            ])
    }

    static func checkInput(_ material: CheckMaterial = checkMaterial()) -> RuleCheckJobInput {
        RuleCheckJobInput(
            ruleCheckID: UUID(), ruleVersionID: UUID(), hook: .taskBeforeSubmit, taskID: UUID(), material: material)
    }

    static func draftMaterial(
        criteria: [CriterionInput] = [CriterionInput(text: "The walrus discount is named.", kind: .build)],
        workReference: String? = "/Users/example/sites/alpaca", rank: Int? = 2, budget: Decimal? = 12.5
    ) -> DraftMaterial {
        DraftMaterial(
            roleFile: "You are the planner. You write a task's contract.", title: title, goal: goal,
            details: details, criteria: criteria, workReference: workReference, minimumStrengthRank: rank,
            budgetCap: budget)
    }

    static func draftInput(_ material: DraftMaterial = draftMaterial()) -> ContractDraftJobInput {
        ContractDraftJobInput(taskID: UUID(), material: material)
    }

    static func checkClaim(
        _ input: RuleCheckJobInput = checkInput(), jobID: UUID = UUID(), runDueAt: Date = Date().addingTimeInterval(300)
    ) -> JobClaim {
        JobClaim(jobID: jobID, kind: .ruleCheck, input: .ruleCheck(input), runDueAt: runDueAt)
    }

    static func draftClaim(
        _ input: ContractDraftJobInput = draftInput(), jobID: UUID = UUID(),
        runDueAt: Date = Date().addingTimeInterval(300)
    ) -> JobClaim {
        JobClaim(jobID: jobID, kind: .contractDraft, input: .contractDraft(input), runDueAt: runDueAt)
    }

    /// The nonce a check or draft prompt asks its answer to carry: the last
    /// one its closing names.
    static func nonce(of prompt: String) -> String? {
        let pattern = /LEVERAGE-(?:VERDICT|DRAFT)-([0-9a-f]{12})/
        return prompt.matches(of: pattern).last.map { String($0.output.1) }
    }

    /// A driver that answers every check prompt with `word` and `reason`,
    /// on the prompt's own nonce.
    static func answering(_ word: String, reason: String = "The made-up checker says so.", tokens: Int = 7)
        -> ScriptedDriver {
        ScriptedDriver { prompt, _ in
            guard let nonce = nonce(of: prompt) else { return .answer("no nonce in the prompt", tokens: tokens) }
            return .answer(
                "I read it.\nLEVERAGE-VERDICT-\(nonce): \(word)\nLEVERAGE-REASON-\(nonce): \(reason)", tokens: tokens)
        }
    }
}

/// A clock a test moves itself: `pause` waits until the clock has moved on by
/// the duration, so nothing waits on real time.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Double = 0
    let start: Date

    init(start: Date = Date(timeIntervalSince1970: 1_900_000_000)) { self.start = start }

    var seconds: Double { lock.withLock { elapsed } }
    func advance(by seconds: Double) { lock.withLock { elapsed += seconds } }
    var now: Date { start.addingTimeInterval(seconds) }

    /// Waits until the clock has moved `duration` past where it was.
    func pause(_ duration: Duration) async throws {
        let target = seconds + Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        while seconds < target {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func timing(poll: Duration = .seconds(30)) -> RunnerTiming {
        var timing = RunnerTiming.fast()
        timing.jobPollInterval = poll
        timing.pause = { [self] in try await pause($0) }
        timing.now = { [self] in now }
        return timing
    }
}

extension Harness {
    /// A flow context over the harness's fake API, for a job's own tests.
    func context(
        driver: any ToolDriver, timing: RunnerTiming = .fast(), interruption: Interruption? = nil,
        state: RunnerState = RunnerState(), log: Log = Log(component: "job-test", write: { _ in })
    ) -> FlowContext {
        FlowContext(
            api: api, driver: driver, timing: timing, log: log, state: state, workRoot: workRoot,
            home: folder.url.path, interruption: interruption ?? Interruption(provider: .claude, hasCredential: false))
    }
}

/// Lines a test collects from a `Log`.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var log: Log { Log(component: "job-test", write: { [self] line in lock.withLock { stored.append(line) } }) }
    var lines: [String] { lock.withLock { stored } }
}
