import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// What the rule-check tests share (milestone 4 plan §5.2, RT-8, RT-9):
// each starts at the first sign-in on a database of its own, which
// scripts/e2e_rule_checks.sh starts for that one test, so creating the owner
// writes the seven shipped rules, on. The helper starts every agent, an
// orchestrator among them, as it starts a builder. The stand-ins answer
// checks and drafts as the test's scenario says, and count prompts; nothing
// reads a clock. Every wait is a long poll on the owner's log or inbox
// under a deadline.

/// The rule-check tests run only when scripts/e2e_rule_checks.sh started
/// their database (`LEVERAGE_E2E=rule_checks`).
let ruleChecksEnabled = ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "rule_checks"

/// The deadline of every wait but the one that measures L401's 90 seconds.
let ruleCheckDeadline: Double = 120

/// The scenario the stand-ins follow, with the check and draft keys of
/// `provider_tool.py` (plan §2.2), which `StandInScenario` does not carry.
struct RuleChecksScenario: Encodable {
    var reviews: [StandInScenario.Review] = [.init()]
    /// The verdicts of the first check prompts of this copy, in order;
    /// PASSED after the list.
    var checkVerdicts: [String]?
    /// FAILED for a check prompt with this text inside a quote block.
    var checkFailWhenContains: String?
    /// The reason of every verdict is the first line of this file.
    var checkReasonFromFile: String?
}

/// One rule-check test's world: its folder, its copy of the stand-ins, the
/// owner, the helper, the event follower, and the marker words of its task
/// text (RT-8), which the script looks for in every event's payload and
/// every log line.
struct RuleChecksWorld {
    let folder: TestFolder
    let tools: StandInTools
    let work: URL
    let owner: OwnerClient
    let follower: EventFollower
    let helper: RunningHelper
    let markers: [String]

    /// Writes the scenario; the checker's reason holds the test's last
    /// marker word, so the checker's reason is task text the scan looks for.
    func write(_ scenario: RuleChecksScenario) throws {
        var scenario = scenario
        let reason = folder.url.appendingPathComponent("checker-reason.txt")
        try Data("The stand-in checker looked for \(markers[markers.count - 1]).\n".utf8).write(to: reason)
        scenario.checkReasonFromFile = reason.path
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try FileManager.default.createDirectory(at: tools.state, withIntermediateDirectories: true)
        try encoder.encode(scenario).write(to: tools.state.appendingPathComponent("scenario.json"))
    }

    /// The checker's reason the stand-ins give with the scenario above.
    var checkerReason: String { "The stand-in checker looked for \(markers[markers.count - 1])." }

    /// Add credential as the app sends it: the catalog's default model for
    /// the provider, or none where it names none, and rank 1 (HE-5).
    func addLogin(_ provider: Provider, name: String, id: UUID = UUID()) async throws -> UUID {
        try await owner.addLogin(
            provider, name: name, id: id, model: ProviderCatalog.entry(for: provider.rawValue)?.defaultModel?.value,
            strengthRank: 1, deadline: Patience.seconds(120))
    }

    /// The usual three: a builder on Claude "One", a reviewer on Codex
    /// "Team", an orchestrator on Gemini "Studio", each running.
    func usualAgents() async throws -> Agents {
        let one = try await addLogin(.claude, name: "One")
        let team = try await addLogin(.codex, name: "Team")
        let studio = try await addLogin(.gemini, name: "Studio")
        let builder = try await owner.connect("Builder", role: .builder, login: one)
        let reviewer = try await owner.connect("Reviewer", role: .reviewer, login: team)
        let orchestrator = try await owner.connect("Orchestrator", role: .orchestrator, login: studio)
        try await owner.waitUntilRunning([builder, reviewer, orchestrator])
        return Agents(
            builder: builder, reviewer: reviewer, orchestrator: orchestrator,
            builderLogin: one, reviewerLogin: team, orchestratorLogin: studio)
    }

    /// Add task, then Complete contract: the answer is returned as it came
    /// (`pending` while a model check runs). The details carry the test's
    /// first marker word unless `details` is given.
    func addTask(
        title: String, details: String? = nil, criteria: [String] = ["criterion-1.txt exists."]
    ) async throws -> AddedTask {
        let goal = "The end-to-end run reaches Done."
        let addKey = IdempotencyKey()
        let added = try await owner.addTask(
            AddTaskRequest(title: title, goal: goal, priority: .normal, workReference: work.path, state: .backlog),
            key: addKey)
        guard let task = try added.completedResult()?.taskID else {
            throw EndToEndFailure("add_task answered no task")
        }
        let contract = try await completeContract(
            task, title: title, goal: goal, details: details ?? "The run's details name \(markers[0]).",
            criteria: criteria)
        return AddedTask(task: task, addKey: addKey, contractKey: contract.key, contract: contract.outcome)
    }

    /// Complete contract on `task` with a new key.
    func completeContract(
        _ task: UUID, title: String, goal: String = "The end-to-end run reaches Done.", details: String,
        criteria: [String] = ["criterion-1.txt exists."]
    ) async throws -> (key: IdempotencyKey, outcome: PlainOutcome) {
        let key = IdempotencyKey()
        let request = CompleteContractRequest(
            title: title, goal: goal, details: details,
            criteria: criteria.map { CriterionInput(text: $0) }
                + [CriterionInput(text: "An independent reviewer agrees.", kind: .review)],
            workReference: work.path)
        return (key, try await owner.completeContract(taskID: task, request, key: key))
    }

    /// The shipped rule with this key.
    func shippedRule(_ key: String) async throws -> RuleRow {
        try #require(try await owner.listRules().rules.first { $0.rule.key == key }, "the shipped rule \(key)")
    }

    func waitFor(
        _ what: String, deadline: Double = ruleCheckDeadline, task: UUID? = nil,
        where matches: @escaping @Sendable (EventRecord) -> Bool
    ) async throws -> EventRecord {
        try await follower.wait(
            for: what, deadline: deadline,
            failing: { event in task.map { event.taskID == $0 && event.type == .taskCancelled } ?? false },
            where: matches)
    }

    func waitForDone(_ task: UUID, deadline: Double = 180) async throws -> EventRecord {
        try await waitFor("task.done", deadline: deadline, task: task) { $0.taskID == task && $0.type == .taskDone }
    }

    /// The events of the whole log, oldest first.
    func wholeLog() async -> [EventRecord] {
        await follower.seen.sorted { $0.seq < $1.seq }
    }

    /// Stops the seats and waits until every process their runs started is
    /// gone (§5.2).
    func stopSeats(_ seats: [UUID]) async throws {
        for seat in seats { try await owner.stopAndWait(seat: seat) }
        try await eventually("every process the runs started ended", deadline: Patience.seconds(30)) {
            try await Processes.startedBy(helper.process.processID, orNaming: folder.url).isEmpty
        }
    }

    /// The stand-ins' calls of one tool whose prompt has `text`.
    func prompts(_ tool: String, containing text: String) throws -> [String] {
        try tools.calls().filter { $0.tool == tool }.compactMap { call in
            call.argv.first { $0.contains(text) }
        }
    }
}

struct Agents {
    let builder: UUID
    let reviewer: UUID
    let orchestrator: UUID
    let builderLogin: UUID
    let reviewerLogin: UUID
    let orchestratorLogin: UUID

    var all: [UUID] { [builder, reviewer, orchestrator] }
}

struct AddedTask {
    let task: UUID
    let addKey: IdempotencyKey
    let contractKey: IdempotencyKey
    let contract: PlainOutcome
}

/// Starts a rule-check test's world with `markerCount` marker words of its
/// own, runs `body`, and stops the helper whether or not `body` threw.
func withRuleChecksWorld(
    _ name: String, markerCount: Int = 3, _ body: (RuleChecksWorld) async throws -> Void
) async throws {
    let folder = try TestFolder(name)
    let tools = try StandIns.copy(into: folder.url)
    // Antigravity keeps one sign-in for the whole Mac and has no sign-in
    // command of its own: the owner has signed in to it before adding a
    // Gemini login (what scripts/real_gemini_through_app.sh relies on).
    try tools.signIn("agy")
    let work = try folder.folder("work")
    let owner = try await EndToEnd.owner()
    try folder.record(secrets: [
        EndToEnd.ownerPassword, owner.transport.token ?? "",
        StandIns.statusEmail, StandIns.statusOrganisation,
    ].filter { !$0.isEmpty })
    // Each word starts "zq", which no id, key or token holds.
    let markers = (0..<max(1, markerCount)).map { _ in "zq" + UUID().contractString.prefix(8) }
    try folder.record(markers: markers)
    guard let helperToken = try await owner.issueHelperToken(
        name: "End-to-end Mac", idempotencyKey: IdempotencyKey().value) else {
        throw EndToEndFailure("issue_helper_token answered no token")
    }
    try folder.record(secrets: [helperToken])
    let follower = try await EventFollower.fromNow(owner: owner)
    let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)
    let world = RuleChecksWorld(
        folder: folder, tools: tools, work: work, owner: owner, follower: follower, helper: helper,
        markers: markers)
    try world.write(RuleChecksScenario())
    try await withCleanup {
        try await body(world)
    } cleanup: {
        await helper.stop()
    }
}

// MARK: - The checks every test makes (§5.2)

/// Every command's events share its key, and only the sweep's timers write
/// events with none. A command that waited on a model check and completed
/// later writes its later events under the requester's key, each with a
/// cause: an event of another command, earlier in the log.
func checkKeysAndCauses(_ events: [EventRecord]) throws {
    let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
    var firstGroup: [String: Int] = [:]
    for (index, group) in groupedByCommand(events.sorted { $0.seq < $1.seq }).enumerated() {
        guard let key = group.key else {
            #expect(
                group.events.allSatisfy { $0.actorKind == .app },
                "events with no key are a timer's: \(group.events.map(\.type.rawValue))")
            continue
        }
        guard firstGroup[key] != nil else {
            firstGroup[key] = index
            continue
        }
        // A later group under a key seen before: a command completed later.
        for event in group.events {
            let cause = try #require(event.causeID, "\(event.type.rawValue) at seq \(event.seq) under an earlier key has a cause")
            if let caused = byID[cause] {
                #expect(caused.seq < event.seq, "the cause of seq \(event.seq) comes first")
                #expect(caused.commandID != key, "the cause of seq \(event.seq) is another command's")
            }
        }
    }
}

extension TestFolder {
    /// Adds the test's marker words to `markers.txt`, one per line, for the
    /// scan's two task-text questions (RT-8).
    func record(markers: [String]) throws {
        let text = markers.map { "\($0)\n" }.joined()
        let file = url.appendingPathComponent("markers.txt")
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: file)
        }
    }
}
