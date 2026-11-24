import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

/// One real verdict through the server (milestone 4 plan §5.5), run only by
/// scripts/real_rule_check.sh, which sets LEVERAGE_E2E=real_rule_check. On
/// the real path (LEVERAGE_REAL_PROVIDER names the provider) only the
/// managing agent runs it, never in CI; on the stand-in path (the script's
/// LEVERAGE_TOOL_DIR, with LEVERAGE_REAL_PROVIDER unset) any agent may, to
/// prove the plumbing.
///
/// Each test creates the owner, which writes the shipped rules with "Every
/// task needs specific details" on, connects one orchestrator and adds two
/// tasks whose contracts are the first `specific` case and the first
/// `vague_goal` case of evals/specific-details. It passes when the first is
/// Ready and the second is held with contract_incomplete within 5 minutes.
/// The script reads the results folder (event types and ids, the two tasks'
/// states) and runs leverage:verify_log and the secret scan.
enum RealRuleCheck {
    static let environment = ProcessInfo.processInfo.environment

    static var provider: Provider? {
        environment["LEVERAGE_RULE_CHECK_PROVIDER"].flatMap(Provider.init(rawValue:))
            .flatMap { [.claude, .codex, .gemini].contains($0) ? $0 : nil }
    }

    /// The stand-in path: the script was given a copy of the stand-ins.
    static var standIns: Bool { !(environment[EnvironmentKeys.toolDir] ?? "").isEmpty }

    static var enabled: Bool {
        guard environment[EnvironmentKeys.e2e] == "real_rule_check", environment["CI"] == nil,
              let provider else { return false }
        return standIns
            ? environment[EnvironmentKeys.realProvider] == nil
            : environment[EnvironmentKeys.realProvider] == provider.rawValue
    }

    /// The tool the script resolved, absolute.
    static func tool() throws -> String {
        guard let path = environment["LEVERAGE_RULE_CHECK_TOOL"], path.hasPrefix("/") else {
            throw EndToEndFailure("LEVERAGE_RULE_CHECK_TOOL names no absolute path")
        }
        return path
    }

    static func results() throws -> URL {
        guard let path = environment["LEVERAGE_RULE_CHECK_RESULTS"], path.hasPrefix("/") else {
            throw EndToEndFailure("LEVERAGE_RULE_CHECK_RESULTS names no absolute path")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    struct Case {
        let id: String
        let contract: CompleteContractRequest
        let title: String
        let goal: String
    }

    /// The first case of `category`, by file name.
    static func firstCase(_ category: String) throws -> Case {
        let folder = EndToEnd.repositoryRoot.appendingPathComponent("evals/specific-details/cases", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        for name in files {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  file["category"] as? String == category,
                  let contract = file["contract"] as? [String: Any],
                  let title = contract["title"] as? String, let goal = contract["goal"] as? String,
                  let criteria = contract["criteria"] as? [[String: Any]] else { continue }
            let inputs = criteria.compactMap { criterion -> CriterionInput? in
                guard let text = criterion["text"] as? String else { return nil }
                return CriterionInput(text: text, kind: criterion["kind"] as? String == "review" ? .review : .build)
            }
            let request = CompleteContractRequest(
                title: title, goal: goal, details: contract["details"] as? String ?? "", criteria: inputs,
                workReference: contract["work_reference"] as? String)
            return Case(id: file["id"] as? String ?? name, contract: request, title: title, goal: goal)
        }
        throw EndToEndFailure("evals/specific-details has no \(category) case")
    }
}

@Suite("A real rule check", .serialized, .enabled(if: RealRuleCheck.enabled))
struct RealRuleCheckTests {
    @Test("an orchestrator that connects on its own checks a specific and a vague contract")
    func testRunnerOnItsOwn() async throws {
        let provider = try #require(RealRuleCheck.provider)
        let folder = try TestFolder("real-rule-check")
        let owner = try await EndToEnd.owner()
        try folder.record(secrets: [EndToEnd.ownerPassword, owner.transport.token ?? ""].filter { !$0.isEmpty })
        let cases = try (RealRuleCheck.firstCase("specific"), RealRuleCheck.firstCase("vague_goal"))
        try folder.record(markers: [cases.0.title, cases.1.title])
        let tool = try RealRuleCheck.tool()

        let token = try await owner.connectByPrompt("Orchestrator", role: .orchestrator, provider: provider).seatToken
        try folder.record(secrets: [token])

        var environment = [
            EnvironmentKeys.lang: "en_US.UTF-8",
            EnvironmentKeys.apiURL: EndToEnd.apiURL.absoluteString,
            EnvironmentKeys.seatToken: token,
            EnvironmentKeys.seatRole: SeatRole.orchestrator.rawValue,
            EnvironmentKeys.provider: provider.rawValue,
            EnvironmentKeys.toolPath: tool,
            EnvironmentKeys.supportDir: folder.support.path,
            EnvironmentKeys.workRoot: try folder.folder("runner-work").path,
        ]
        if RealRuleCheck.standIns {
            // The copy the script was given: its scenario fails the vague
            // goal and passes the rest, and its sign-in is the stand-ins'.
            let standIns = URL(fileURLWithPath: tool).deletingLastPathComponent().deletingLastPathComponent()
            try writeScenario(failing: cases.1.goal, in: standIns)
            environment[EnvironmentKeys.path] = "/usr/bin:/bin"
            environment[EnvironmentKeys.home] = try folder.folder("home").path
            environment[EnvironmentKeys.toolDir] = standIns.appendingPathComponent("bin").path
            if provider == .gemini {
                try Data("signed in\n".utf8).write(to: standIns.appendingPathComponent("state/signed-in-agy"))
            } else {
                let account = try folder.folder("account")
                try Data("signed in\n".utf8).write(to: account.appendingPathComponent(".standin-signed-in"))
                environment[EnvironmentKeys.settingsDir] = account.path
            }
        } else {
            // The real tool, on the sign-in it already holds for this Mac
            // user: nobody signs in, and no account folder is named.
            let inherited = ProcessInfo.processInfo.environment
            environment[EnvironmentKeys.path] = inherited[EnvironmentKeys.path] ?? "/usr/bin:/bin"
            environment[EnvironmentKeys.home] = inherited[EnvironmentKeys.home] ?? NSHomeDirectory()
            // As the helper hands them to a runner (RunnerEnvironment): Claude
            // Code finds its sign-in in the Keychain only with USER set, and
            // without it answers "Not logged in".
            for key in [EnvironmentKeys.user, EnvironmentKeys.tmpdir] {
                if let value = inherited[key] { environment[key] = value }
            }
            environment[EnvironmentKeys.devToolLogin] = "1"
        }
        try FileManager.default.createDirectory(at: folder.logs, withIntermediateDirectories: true)
        let runner = try Subprocess.start(SubprocessRequest(
            executable: try EndToEnd.program("LeverageRunner").path, arguments: [], environment: environment,
            gracePeriod: .seconds(20)))
        let follower = try await EventFollower.fromNow(owner: owner)

        try await withCleanup {
            try await checkTwoContracts(owner: owner, follower: follower, cases: cases, folder: folder)
        } cleanup: {
            runner.stop()
            let result = await runner.wait()
            try? (result.standardOutput + result.standardError)
                .write(to: folder.logs.appendingPathComponent("orchestrator-runner.log"))
        }
    }

    @Test("an orchestrator the helper starts on a Gemini login checks a specific and a vague contract")
    func testThroughTheApp() async throws {
        let provider = try #require(RealRuleCheck.provider)
        try #require(provider == .gemini, "only a Gemini login is added with no sign-in")
        let folder = try TestFolder("real-rule-check-app")
        let owner = try await EndToEnd.owner()
        try folder.record(secrets: [EndToEnd.ownerPassword, owner.transport.token ?? ""].filter { !$0.isEmpty })
        let cases = try (RealRuleCheck.firstCase("specific"), RealRuleCheck.firstCase("vague_goal"))
        try folder.record(markers: [cases.0.title, cases.1.title])

        var tools: StandInTools?
        if RealRuleCheck.standIns {
            let copy = try StandIns.copy(into: folder.url)
            try copy.signIn("agy")
            try writeScenario(failing: cases.1.goal, in: copy.root)
            tools = copy
        }
        guard let helperToken = try await owner.issueHelperToken(
            name: "Real rule check", idempotencyKey: IdempotencyKey().value) else {
            throw EndToEndFailure("issue_helper_token answered no token")
        }
        try folder.record(secrets: [helperToken])
        let follower = try await EventFollower.fromNow(owner: owner)
        let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)

        try await withCleanup {
            let gemini = try await owner.addLogin(.gemini, name: "Gemini (real rule check)", deadline: 600)
            let orchestrator = try await owner.connect("Orchestrator", role: .orchestrator, login: gemini)
            try await owner.waitUntilRunning([orchestrator])
            try await checkTwoContracts(owner: owner, follower: follower, cases: cases, folder: folder)
            try await owner.stopAndWait(seat: orchestrator)
        } cleanup: {
            await helper.stop()
        }
    }
}

/// The stand-ins' scenario: FAILED for a check prompt that quotes `text`.
private func writeScenario(failing text: String, in standIns: URL) throws {
    let state = standIns.appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["check_fail_when_contains": text])
        .write(to: state.appendingPathComponent("scenario.json"))
}

/// Adds the two tasks, waits at most 5 minutes for the first to be Ready
/// and the second held with contract_incomplete, and writes the results:
/// the two tasks' events (types and ids, no payload) and their states.
private func checkTwoContracts(
    owner: OwnerClient, follower: EventFollower, cases: (RealRuleCheck.Case, RealRuleCheck.Case), folder: TestFolder
) async throws {
    var tasks: [UUID] = []
    for item in [cases.0, cases.1] {
        let added = try await owner.addTask(
            AddTaskRequest(
                title: item.title, goal: item.goal, priority: .normal, workReference: item.contract.workReference,
                state: .backlog),
            key: IdempotencyKey())
        let task = try #require(try added.completedResult()?.taskID)
        let outcome = try await owner.completeContract(taskID: task, item.contract, key: IdempotencyKey())
        #expect(outcome.outcome == .pending, "\(item.id): Complete contract waits for the check")
        tasks.append(task)
    }
    let (specific, vague) = (tasks[0], tasks[1])
    let deadline: Double = 300
    let started = Date()
    _ = try await follower.wait(for: "\(cases.0.id) Ready", deadline: deadline, where: {
        $0.taskID == specific && $0.type == .taskReady
    })
    _ = try await follower.wait(
        for: "\(cases.1.id) held with contract_incomplete",
        deadline: max(1, deadline - Date().timeIntervalSince(started)),
        where: { $0.taskID == vague && $0.type == .holdOpened && $0.string("reason") == "contract_incomplete" })

    let results = try RealRuleCheck.results()
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    var lines: [String] = []
    for (name, task) in [(cases.0.id, specific), (cases.1.id, vague)] {
        for event in await follower.events(of: task) {
            lines.append("\(name) \(event.seq) \(event.type.rawValue) actor=\(event.actorKind.rawValue) "
                + "subject=\(event.subjectKind?.rawValue ?? "-")")
        }
    }
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: results.appendingPathComponent("events.txt"))
    var states: [String] = []
    for (name, task) in [(cases.0.id, specific), (cases.1.id, vague)] {
        let page = try await owner.task(id: task)
        let holds = page.holds.filter { $0.closedAt == nil }.map(\.reason.rawValue).sorted()
        let checks = page.ruleChecks.map { "\($0.ruleName): \($0.result?.rawValue ?? "pending")" }
        states.append("\(name): \(page.task.state.rawValue); holds: \(holds.joined(separator: ", ")); "
            + "checks: \(checks.joined(separator: "; "))")
    }
    try Data((states.joined(separator: "\n") + "\n").utf8).write(to: results.appendingPathComponent("tasks.txt"))
}
