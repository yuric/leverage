import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

let questionsApprovalsEnabled = ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "questions_approvals"

struct QuestionsApprovalsScenario: Encodable {
    var approvalDecisions: [String]?
    var actionResults: [String]?
    var reviewGateFile: String?
    var actionTouchFile: String?
    var actionGateFile: String?
    var questionAnswers: [String]?
    var checkReasonFromFile: String?
}

final class QuestionsApprovalsWorld {
    let folder: TestFolder
    let tools: StandInTools
    let owner: OwnerClient
    let follower: EventFollower
    let work: URL
    private let helper: RunningHelper
    private let markers: [String: String]
    private var managedSeats: [UUID] = []
    private(set) var reviewer: UUID!
    private(set) var orchestrator: UUID!

    init(folder: TestFolder, tools: StandInTools, owner: OwnerClient, helper: RunningHelper) throws {
        self.folder = folder
        self.tools = tools
        self.owner = owner
        self.helper = helper
        follower = EventFollower(owner: owner)
        work = try folder.folder("work")
        let fields = ["action", "reason", "details", "question", "assumption", "answer", "access", "brief"]
        markers = Dictionary(uniqueKeysWithValues: fields.map { ($0, "zq" + UUID().contractString.prefix(12)) })
    }

    func marker(_ field: String) -> String {
        guard let marker = markers[field] else { preconditionFailure("unknown test content field") }
        return marker
    }

    func start(_ scenario: QuestionsApprovalsScenario) async throws {
        var scenario = scenario
        let reason = folder.url.appendingPathComponent("checker-reason.txt")
        try Data("The stand-in checked \(marker("reason")).\n".utf8).write(to: reason)
        scenario.checkReasonFromFile = reason.path
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try FileManager.default.createDirectory(at: tools.state, withIntermediateDirectories: true)
        try encoder.encode(scenario).write(to: tools.state.appendingPathComponent("scenario.json"))

        let rules = try await owner.listRules().rules.filter { $0.version.origin == .shipped }
        #expect(rules.count == 7 && rules.allSatisfy { $0.rule.enabled })
        reviewer = try await connectManaged("Reviewer", role: .reviewer, provider: .codex, login: "Team")
        orchestrator = try await connectManaged("Orchestrator", role: .orchestrator, provider: .gemini, login: "Studio")
    }

    private func connectManaged(_ name: String, role: SeatRole, provider: Provider, login: String) async throws -> UUID {
        let credential = try await owner.addLogin(
            provider, name: login, model: ProviderCatalog.entry(for: provider.rawValue)?.defaultModel?.value,
            strengthRank: 1, deadline: Patience.seconds(120))
        let seat = try await owner.connect(name, role: role, login: credential)
        managedSeats.append(seat)
        // Run state is a read, with no corresponding event.
        try await eventually("the managed seat is running", deadline: Patience.seconds(120)) {
            try await self.owner.seats().seats.first { $0.id == seat }?.runState == .running
        }
        if role == .orchestrator {
            try await eventually("the orchestrator has polled", deadline: Patience.seconds(120)) {
                try await self.owner.seats().seats.first { $0.id == seat }?.lastPolledAt != nil
            }
        }
        return seat
    }

    func managedBuilder(name: String = "One") async throws -> UUID {
        try await connectManaged("Builder \(name)", role: .builder, provider: .claude, login: name)
    }

    func manualBuilder(_ name: String = "Builder") async throws -> (seat: UUID, client: AgentClient, token: String) {
        let outcome = try await owner.connectSeat(
            ConnectSeatRequest(name: name, role: .builder, provider: .claude), key: IdempotencyKey())
        guard case .shown(let seat)? = try outcome.completedResult(), let token = seat.seatToken else {
            throw EndToEndFailure("Connect seat did not issue a token to the builder")
        }
        return (seat.seatID, AgentClient(baseURL: EndToEnd.apiURL, seatToken: token), token)
    }

    func addTask(
        title: String, projectID: UUID? = nil, actions: [ActionInput] = [],
        criteria: [String] = ["criterion-1.txt exists."]
    ) async throws -> AddedTask {
        let goal = "The end-to-end run reaches Done."
        let addKey = IdempotencyKey()
        let added = try await owner.addTask(
            AddTaskRequest(
                title: title, goal: goal, actions: actions, projectID: projectID, priority: .normal,
                workReference: work.path, state: .backlog),
            key: addKey)
        guard let task = try added.completedResult()?.taskID else { throw EndToEndFailure("Add task returned no task") }
        let contractKey = IdempotencyKey()
        let result = try await owner.completeContract(
            taskID: task,
            CompleteContractRequest(
                title: title, goal: goal, details: "The fixture mentions \(marker("details")).",
                criteria: criteria.map { CriterionInput(text: $0) }
                    + [CriterionInput(text: "An independent reviewer agrees.", kind: .review)],
                actions: actions, workReference: work.path),
            key: contractKey)
        guard result.outcome == .pending else {
            throw EndToEndFailure("Complete contract did not wait for the shipped model check")
        }
        return AddedTask(task: task, addKey: addKey, contractKey: contractKey, contract: result)
    }

    @discardableResult
    func waitFor(
        _ what: String, task: UUID? = nil, where matches: @escaping @Sendable (EventRecord) -> Bool
    ) async throws -> EventRecord {
        try await follower.wait(
            for: what, deadline: Patience.seconds(120),
            failing: { event in task.map { event.taskID == $0 && event.type == .taskCancelled } ?? false },
            where: matches)
    }

    @discardableResult
    func waitForDone(_ task: UUID) async throws -> EventRecord {
        try await waitFor("task.done", task: task) { $0.taskID == task && $0.type == .taskDone }
    }

    func wholeLog() async throws -> [EventRecord] {
        var events: [EventRecord] = []
        var after = 0
        while true {
            let page = try await owner.events(afterSeq: after, limit: 500, wait: nil)
            if page.events.isEmpty { return events }
            events += page.events
            after = page.nextAfterSeq
        }
    }

    func verify() async throws {
        for seat in managedSeats { try await owner.stopAndWait(seat: seat) }
        try await eventually("the runs ended", deadline: Patience.seconds(120)) {
            try await Processes.startedBy(helper.process.processID, orNaming: folder.url).isEmpty
        }
        try checkKeysAndCauses(try await wholeLog())
        // Write after the live checks, so a skipped or incomplete test cannot
        // satisfy the shell driver's run count.
        try folder.record(markers: markers.sorted { $0.key < $1.key }.map(\.value))
    }
}

func withQuestionsApprovalsWorld(
    _ name: String,
    configure: (QuestionsApprovalsWorld) throws -> QuestionsApprovalsScenario = { _ in .init() },
    _ body: (QuestionsApprovalsWorld) async throws -> Void
) async throws {
    let folder = try TestFolder(name)
    let tools = try StandIns.copy(into: folder.url)
    try tools.signIn("agy")
    let owner = try await EndToEnd.owner()
    guard let helperToken = try await owner.issueHelperToken(
        name: "End-to-end Mac", idempotencyKey: IdempotencyKey().value
    ) else { throw EndToEndFailure("Issue helper token returned no token") }
    let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)
    try await withCleanup {
        let world = try QuestionsApprovalsWorld(folder: folder, tools: tools, owner: owner, helper: helper)
        try await world.start(configure(world))
        try await body(world)
        try await world.verify()
    } cleanup: {
        await helper.stop()
    }
}

/// Like the handoff matcher, with diagnostics limited to event types and
/// sequence numbers so a failing test cannot echo a leaked content field.
@discardableResult
func questionsApprovalsOrder(_ events: [EventRecord], after start: Int = 0, _ expected: [Expected]) throws -> [EventRecord] {
    var found: [EventRecord] = []
    var after = start
    for item in expected {
        guard let event = events.first(where: { $0.seq > after && item.matches($0) }) else {
            let timeline = events.filter { $0.seq > start }.map { "\($0.seq) \($0.type.rawValue)" }.joined(separator: ", ")
            throw EndToEndFailure("no \(item.what) after seq \(after). Timeline: \(timeline)")
        }
        found.append(event)
        after = event.seq
    }
    return found
}
