import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// What the six handoff tests share (milestone 3 plan §5.2): each starts at
// the first sign-in on a database of its own, which scripts/e2e_handoff.sh
// starts for that one test, and each plays its interruption with the
// stand-ins' directives (HD-11), which count prompts and read no clock.
// Nothing waits a fixed time: every wait is a long poll under a deadline.

/// The handoff tests run only when scripts/e2e_handoff.sh started their
/// database (`LEVERAGE_E2E=handoff`). The core loop's script sets `1`, so
/// neither script runs the other's tests on its database.
let handoffEnabled = ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "handoff"

/// The working bar the runs are checked against while the owner has set no
/// recovery time ceiling (plan HE-1). It is given to this check alone.
let workingBarSeconds = 900

/// How a recovery time must end (plan HE-17).
enum Recovery: Equatable {
    /// Another account took over in the report's own command: 0 seconds,
    /// ending at that command's `credential.switched`.
    case handedOff
    /// The task waited: it ends at the continuing seat's first event, a
    /// `criterion.started` (HD-9), not at the hold's close or the switch.
    case waited
}

/// One handoff test's world: its folder, its copy of the stand-ins, the
/// owner, the helper, and the event follower.
struct HandoffWorld {
    let folder: TestFolder
    let tools: StandInTools
    let work: URL
    let owner: OwnerClient
    let follower: EventFollower
    let helper: RunningHelper

    /// The settings folder the helper makes for a login of a provider that
    /// keeps its accounts in folders (`<support>/accounts/<id>`), known
    /// before the login is added, so the scenario can name it.
    func accountFolder(_ credential: UUID) -> URL {
        folder.support.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(credential.contractString, isDirectory: true)
    }

    /// Add credential as the app sends it: the catalog's default model for
    /// the provider, or none where it names none, and rank 1 (HE-5).
    func addLogin(_ provider: Provider, name: String, id: UUID = UUID()) async throws -> UUID {
        try await owner.addLogin(
            provider, name: name, id: id, model: Self.defaultModel(provider), strengthRank: 1)
    }

    static func defaultModel(_ provider: Provider) -> String? {
        ProviderCatalog.entry(for: provider.rawValue)?.defaultModel?.value
    }

    /// Plays the owner signing a login out in its own tool, outside leverage.
    func signOutInTool(_ tool: String, account: URL) throws {
        try FileManager.default.removeItem(at: account.appendingPathComponent(".standin-signed-in"))
    }

    func waitForDone(_ task: UUID, deadline: Double = 180) async throws -> EventRecord {
        try await follower.wait(
            for: "task.done", deadline: deadline,
            failing: { $0.taskID == task && $0.type == .taskCancelled },
            where: { $0.taskID == task && $0.type == .taskDone })
    }

    /// Stops both seats and waits until every process their runs started is
    /// gone.
    func stopSeats(_ seats: [UUID]) async throws {
        for seat in seats { try await owner.stopAndWait(seat: seat) }
        try await eventually("every process the runs started ended", deadline: 30) {
            try await Processes.startedBy(helper.process.processID, orNaming: folder.url).isEmpty
        }
    }
}

/// Starts a handoff test's world, runs `body`, and stops the helper whether
/// or not `body` threw.
func withHandoffWorld(_ name: String, _ body: (HandoffWorld) async throws -> Void) async throws {
    let folder = try TestFolder(name)
    let tools = try StandIns.copy(into: folder.url)
    let work = try folder.folder("work")
    let owner = try await EndToEnd.owner()
    try folder.record(secrets: [
        EndToEnd.ownerPassword, owner.transport.token ?? "",
        StandIns.statusEmail, StandIns.statusOrganisation,
    ].filter { !$0.isEmpty })
    guard let helperToken = try await owner.issueHelperToken(
        name: "End-to-end Mac", idempotencyKey: IdempotencyKey().value) else {
        throw EndToEndFailure("issue_helper_token answered no token")
    }
    try folder.record(secrets: [helperToken])
    let follower = try await EventFollower.fromNow(owner: owner)
    let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)
    let world = HandoffWorld(
        folder: folder, tools: tools, work: work, owner: owner, follower: follower, helper: helper)
    try await withCleanup {
        try await body(world)
    } cleanup: {
        await helper.stop()
    }
}

// MARK: - Order of events

/// One expected event in a task's log: a description and what matches it.
struct Expected: Sendable {
    let what: String
    let matches: @Sendable (EventRecord) -> Bool

    init(_ what: String, _ matches: @escaping @Sendable (EventRecord) -> Bool) {
        self.what = what
        self.matches = matches
    }

    static func type(_ type: EventType, _ also: @escaping @Sendable (EventRecord) -> Bool = { _ in true }) -> Expected {
        Expected(type.rawValue) { $0.type == type && also($0) }
    }
}

/// The events matched, in order, each after the one before; throws naming
/// the first one missing and what the log held.
@discardableResult
func inOrder(_ events: [EventRecord], after start: Int = 0, _ expected: [Expected]) throws -> [EventRecord] {
    var found: [EventRecord] = []
    var from = start
    for item in expected {
        guard let event = events.first(where: { $0.seq > from && item.matches($0) }) else {
            // Ids and fixed words only: no payload here holds a secret.
            let log = events.filter { $0.seq > start }.map { event in
                let fields = event.payload.keys.sorted()
                    .map { key in "\(key)=\(event.payload[key]?.stringValue ?? "-")" }
                    .joined(separator: " ")
                return "\(event.seq) \(event.type.rawValue) task=\(event.taskID?.contractString ?? "-") "
                    + "subject=\(event.subjectID?.contractString ?? "-") actor=\(event.actorKind.rawValue) \(fields)"
            }
            throw EndToEndFailure("no \(item.what) after seq \(from); the log after seq \(start): \(log)")
        }
        found.append(event)
        from = event.seq
    }
    return found
}

extension EventRecord {
    func string(_ key: String) -> String? { payload[key]?.stringValue }
    func id(_ key: String) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }
}

// MARK: - The checks every test makes once its task is Done

/// The saved work is intact, the recovery times are recorded as HE-17
/// defines them, and every command's events share its key (plan §5.2).
func checkHandoff(
    _ world: HandoffWorld, task: UUID, builder: UUID, recoveries expected: [Recovery]
) async throws {
    let events = await world.follower.events(of: task)
    let page = try await world.owner.task(id: task)
    let build = page.criteria.filter { $0.kind == .build }.sorted { $0.position < $1.position }
    let first = try #require(build.first, "the task has its build criteria")
    let reports = events.filter { [.credentialLimitReached, .credentialSignedOut].contains($0.type) }
    let interruption = try #require(reports.first, "the task's log holds the interruption")

    // The saved work is intact.
    let passed = events.filter { $0.type == .criterionPassed && $0.subjectID == first.id }
    let evidence = events.filter { $0.type == .evidenceAttached && $0.id("criterion_id") == first.id }
    #expect(passed.count == 1 && passed.allSatisfy { $0.seq < interruption.seq }, "criterion 1 passed once, before")
    #expect(evidence.count == 1 && evidence.allSatisfy { $0.seq < interruption.seq }, "its evidence, once, before")
    #expect(!events.contains { $0.type == .criterionReopened })
    #expect(first.state == .passed)
    #expect(first.evidence.map(\.id) == evidence.map { $0.subjectID }.compactMap { $0 })
    let claims = events.filter { $0.type == .taskClaimed }
    #expect(claims.count == 1 && claims.first?.actorID == builder, "one claim, by the builder")
    #expect(page.task.builderSeatID == builder)
    #expect(page.task.state == .done)

    // The recovery times.
    let times = page.recoveryTimes.sorted { $0.startedAt < $1.startedAt }
    #expect(times.count == expected.count, "one recovery time per interruption: \(times)")
    for (index, (time, mode)) in zip(times, expected).enumerated() {
        let report = try #require(reports.count > index ? reports[index] : nil)
        #expect(time.credentialID == report.subjectID)
        #expect(abs(time.startedAt.timeIntervalSince(report.at)) < 0.001, "it starts at the report")
        let ended = try #require(time.endedAt, "recovery time \(index + 1) is closed")
        let seconds = try #require(time.seconds)
        #expect(seconds <= workingBarSeconds, "recovery time \(index + 1): \(seconds) s")
        switch mode {
        case .handedOff:
            let switched = try #require(events.first {
                $0.type == .credentialSwitched && $0.commandID == report.commandID && $0.seq > report.seq
            }, "the report's own command switched the account")
            #expect(time.endedBy == .handoff)
            #expect(seconds == 0)
            #expect(abs(ended.timeIntervalSince(switched.at)) < 0.001, "it ends at the switch")
        case .waited:
            let next = try #require(
                events.first { $0.seq > report.seq && $0.actorKind == .seat && $0.actorID == builder },
                "the builder went on after the wait")
            #expect(next.type == .criterionStarted, "the continuing seat's first event is \(next.type.rawValue)")
            #expect(time.endedBy == .seatEvent)
            // Not at the app's hold.closed or credential.switched before it.
            #expect(abs(ended.timeIntervalSince(next.at)) < 0.001, "it ends at the continuing seat's first event")
        }
    }

    // Every command's events share its key; only the sweep's timers write
    // events with none, as the app.
    let groups = groupedByCommand(events)
    let keyed = groups.compactMap(\.key)
    #expect(Set(keyed).count == keyed.count, "one key per command")
    for group in groups where group.key == nil {
        #expect(group.events.allSatisfy { $0.actorKind == .app }, "a timer's events: \(group.events.map(\.type))")
    }
    for report in reports {
        #expect(report.commandID != nil && report.actorKind == .app, "the helper's report carries its key")
    }
}
