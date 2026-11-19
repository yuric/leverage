import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// What the runner's tests share: made-up contract values, a queue of
// answers, a tool driver that follows a script, and a way to run the loop
// to its end under a deadline.

enum Fixture {
    static let seatID = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!

    static func criterion(
        _ taskID: UUID, _ position: Int, _ text: String, kind: CriterionKind = .build,
        state: CriterionState = .open, id: UUID = UUID()
    ) -> Criterion {
        Criterion(id: id, taskID: taskID, position: position, text: text, kind: kind, state: state)
    }

    static func briefing(hash: String, criteria: [Criterion], roleFile: String = "You build what the contract asks.")
        -> Briefing {
        Briefing(
            hash: hash,
            versions: BriefingVersions(roleFileVersion: "0.0.0", contractVersion: 1),
            roleFile: roleFile,
            contract: BriefingContract(
                contractVersion: 1, goal: "The page shows this year's prices.",
                details: "Use the figures in the price list.", criteria: criteria))
    }

    static func task(_ id: UUID, workReference: String?) -> TaskSummary {
        TaskSummary(id: id, title: "Update the pricing page", goal: "The page shows this year's prices.",
                    state: .working, holderSeatID: seatID, builderSeatID: seatID, workReference: workReference)
    }

    static func claim(_ taskID: UUID, criteria: [Criterion], workReference: String?, hash: String = "hash-0")
        -> TaskClaim {
        TaskClaim(
            task: task(taskID, workReference: workReference),
            lease: Lease(seatID: seatID, leaseDueAt: Date().addingTimeInterval(3600)),
            briefing: briefing(hash: hash, criteria: criteria), workReference: workReference,
            credentialID: UUID(), model: nil)
    }

    static func reviewClaim(
        _ reviewID: UUID, taskID: UUID, criteria: [Criterion], workReference: String?, hash: String = "review-0"
    ) -> ReviewClaim {
        ReviewClaim(
            review: Review(id: reviewID, taskID: taskID, round: 0, reviewerSeatID: seatID),
            lease: Lease(seatID: seatID, leaseDueAt: Date().addingTimeInterval(3600)),
            briefing: briefing(hash: hash, criteria: criteria, roleFile: "You review the work."),
            workReference: workReference, credentialID: UUID(), model: nil)
    }

    static func done(_ command: CommandName) -> PlainOutcome {
        .completed(.object([:]), key: "k", command: command)
    }

    static func refused(_ code: RefusalCode, _ command: CommandName) -> PlainOutcome {
        .refused(Refusal(code: code, ruleID: nil, reason: nil), key: "k", command: command)
    }

    static func beat() -> CommandOutcome<HeartbeatResult> {
        .completed(HeartbeatResult(leaseDueAt: Date().addingTimeInterval(3600)), key: "k", command: .heartbeat)
    }
}

/// Answers handed out in order; once they are used up, `then` answers.
final class Queue<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Item]
    private let then: @Sendable () -> Item

    init(_ items: [Item], then: @escaping @Sendable () -> Item) {
        self.items = items
        self.then = then
    }

    func next() -> Item {
        let item: Item? = lock.withLock { items.isEmpty ? nil : items.removeFirst() }
        return item ?? then()
    }
}

/// A counter several tasks may touch.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// A tool driver that follows a script instead of running a tool.
final class ScriptedDriver: ToolDriver, @unchecked Sendable {
    enum Step: Sendable {
        case answer(String, tokens: Int)
        case fail(ToolFailure)
        /// Runs until it is cancelled, as a long tool run does.
        case block
    }

    struct Run: Sendable {
        let prompt: String
        let folder: URL
        let purpose: ToolPurpose
    }

    private let lock = NSLock()
    private var recorded: [Run] = []
    private var cancelled = 0
    private let respond: @Sendable (String, ToolPurpose) -> Step

    init(_ respond: @escaping @Sendable (String, ToolPurpose) -> Step) {
        self.respond = respond
    }

    /// Every build answers with an evidence line, every review passes.
    static func agreeable() -> ScriptedDriver {
        ScriptedDriver { _, purpose in
            switch purpose {
            case .build: .answer("Done.\nLEVERAGE-EVIDENCE: proof.txt in the work folder", tokens: 10)
            case .review: .answer("LEVERAGE-CRITERION 1: PASS\nLEVERAGE-NOTES: Fine.", tokens: 10)
            case .check: .answer("ready", tokens: 1)
            }
        }
    }

    var runs: [Run] { lock.withLock { recorded } }
    var cancelledRuns: Int { lock.withLock { cancelled } }

    func run(prompt: String, in folder: URL, purpose: ToolPurpose) async throws -> ToolAnswer {
        lock.withLock { recorded.append(Run(prompt: prompt, folder: folder, purpose: purpose)) }
        switch respond(prompt, purpose) {
        case .answer(let text, let tokens):
            return ToolAnswer(text: text, tokens: tokens)
        case .fail(let failure):
            throw failure
        case .block:
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
            throw ToolFailure.timedOut
        }
    }
}

extension RunnerTiming {
    /// No waiting in tests: no long poll, a few milliseconds after an error,
    /// and no heartbeat unless a test asks for one.
    static func fast(heartbeatEvery: Duration = .seconds(3600)) -> RunnerTiming {
        RunnerTiming(
            nextWait: 0, errorPause: .milliseconds(5), idlePause: .milliseconds(5),
            heartbeatInterval: { _, _ in heartbeatEvery })
    }
}

/// A runner loop over a fake API, with its work folders in a temporary
/// folder.
struct Harness {
    let api = FakeAgentAPI()
    let folder: TemporaryFolder
    let workRoot: URL
    /// An existing folder a task's "Where the work is" can name.
    let existingWork: URL

    init() throws {
        folder = try TemporaryFolder(prefix: "leverage-runner")
        workRoot = folder.path("work-root")
        existingWork = try folder.folder("pricing-page")
    }

    func loop(_ role: SeatRole, driver: any ToolDriver, timing: RunnerTiming = .fast()) -> RunnerLoop {
        RunnerLoop(
            role: role, api: api, driver: driver, workRoot: workRoot, home: folder.url.path, timing: timing,
            log: Log(component: "runner-test", write: { _ in }))
    }

    /// `GET /v1/next` answers `items` in order and then stops the loop.
    func next(_ items: [NextItem], then loop: RunnerLoop) {
        let queue = Queue(items) {
            loop.stop()
            return NextItem(kind: .none)
        }
        api.script { $0.next = { _ in queue.next() } }
    }

    /// The operations called, in order.
    var operations: [ContractOperation] { api.calls.map(\.operation) }

    func calls(_ operation: ContractOperation) -> [FakeCall] {
        api.calls.filter { $0.operation == operation }
    }
}

/// Runs the loop to its end; a loop that does not end within the deadline
/// is stopped and the test fails.
func runToEnd(_ loop: RunnerLoop, deadline: Duration = .seconds(30)) async -> Int32 {
    let run = Task { await loop.run() }
    let watchdog = Task {
        try await Task.sleep(for: deadline)
        Issue.record("the runner loop did not end within \(deadline)")
        loop.stop()
    }
    let code = await run.value
    watchdog.cancel()
    return code
}

/// Waits, a few milliseconds at a time, until `condition` holds.
func eventually(within deadline: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: deadline)
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

extension FakeCall {
    var cid: String? { path["cid"] }
    var id: String? { path["id"] }
}
