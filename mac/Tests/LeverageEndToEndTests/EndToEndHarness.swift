import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// What the end-to-end tests share (milestone 2 plan §5.2): the API that
// scripts/e2e_core_loop.sh started, the owner, the real helper and runner
// programs built beside these tests, and waits that long-poll for what they
// need under a deadline. Nothing here waits a fixed time for something to
// happen.

/// A test of the whole loop failed for a reason the test names.
struct EndToEndFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum EndToEnd {
    /// The API `scripts/e2e_core_loop.sh` started (`LEVERAGE_API_URL`).
    static var apiURL: URL { Configuration(environment: ProcessInfo.processInfo.environment).apiBaseURL }

    /// The made-up owner every end-to-end test signs in as. One owner per
    /// installation: the first test creates it, the others sign in.
    static let ownerEmail = "e2e.owner@example.invalid"
    static let ownerPassword = "made-up-e2e-owner-password"

    /// The repository, found from this file's own path.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // LeverageEndToEndTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // mac
        .deletingLastPathComponent()

    /// The folder the build put these tests in, where `LeverageHelper` and
    /// `LeverageRunner` are too (the script builds them first).
    static func productsFolder() throws -> URL {
        #if canImport(Darwin)
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else {
            throw EndToEndFailure("could not find the test program's own path")
        }
        let url = URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
        #else
        // The kernel's link to the running program: readlink, not a path
        // resolution, which can stop at /proc/<pid>/exe.
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else {
            throw EndToEndFailure("could not find the test program's own path")
        }
        let url = URL(fileURLWithPath: path)
        #endif
        return productsFolder(forTestProgram: url)
    }

    /// The products folder for the test program at `program`: the folder
    /// that holds its .xctest bundle (macOS, and older toolchains on Linux),
    /// else the program's own folder (Swift 6.4 on Linux runs the tests from
    /// `LeverageEndToEndTests-test-runner` and `LeverageEndToEndTests.so`).
    static func productsFolder(forTestProgram program: URL) -> URL {
        var url = program
        while url.path != "/" {
            if url.pathExtension == "xctest" { return url.deletingLastPathComponent() }
            url.deleteLastPathComponent()
        }
        return program.deletingLastPathComponent()
    }

    static func program(_ name: String) throws -> URL {
        let url = try productsFolder().appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw EndToEndFailure("\(name) is not built at \(url.path); scripts/e2e_core_loop.sh builds it")
        }
        return url
    }

    /// The owner's client, signed in: creates the owner the first time.
    static func owner() async throws -> OwnerClient {
        let anonymous = OwnerClient(baseURL: apiURL, sessionToken: nil)
        let request = SignInRequest(emailAddress: ownerEmail, password: ownerPassword)
        let outcome = try await anonymous.setupState().ownerExists
            ? anonymous.signIn(request, key: IdempotencyKey())
            : anonymous.createOwner(request, key: IdempotencyKey())
        guard case .shown(let session)? = try outcome.completedResult() else {
            throw EndToEndFailure("signing in answered no session")
        }
        return anonymous.signedIn(sessionToken: session.sessionToken)
    }
}

// MARK: - A test's own folder

/// The folder one end-to-end test works in: its copy of the stand-ins, the
/// helper's support folder and home, the task's work folder, and the list
/// of secrets it used. Under `LEVERAGE_E2E_DIR` when the script sets it, so
/// the logs and the list stay for the secret scan; else a temporary folder.
final class TestFolder: Sendable {
    let url: URL
    private let temporary: TemporaryFolder?

    init(_ name: String) throws {
        if let base = ProcessInfo.processInfo.environment[EnvironmentKeys.e2eFolder], !base.isEmpty {
            url = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("\(name)-\(UUID().contractString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            temporary = nil
        } else {
            let made = try TemporaryFolder(prefix: "e2e-\(name)")
            url = made.url
            temporary = made
        }
    }

    func folder(_ name: String) throws -> URL {
        let made = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    var support: URL { url.appendingPathComponent("support", isDirectory: true) }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }

    /// Adds secrets to `secrets.txt`, one per line, for the secret scan.
    func record(secrets: [String]) throws {
        let file = url.appendingPathComponent("secrets.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secrets.map { "\($0)\n" }.joined().utf8))
    }
}

// MARK: - The real helper

/// The real `LeverageHelper`, started the way the app starts it: with the
/// helper's token in its environment only, a support folder of the test's
/// own and the runner beside it. With stand-ins, `LEVERAGE_TOOL_DIR` points
/// at them and the helper gets a home of the test's own; with `tools` nil
/// (the developer check with the real Antigravity, override 8) it keeps the
/// Mac's home and `PATH`, where the real tool and its one sign-in are.
final class RunningHelper: Sendable {
    let process: RunningSubprocess
    let logFile: URL

    init(token: String, folder: TestFolder, tools: StandInTools?, providerAPIBase: URL? = nil) throws {
        try FileManager.default.createDirectory(at: folder.logs, withIntermediateDirectories: true)
        let inherited = ProcessInfo.processInfo.environment
        var environment = [
            EnvironmentKeys.lang: "en_US.UTF-8",
            EnvironmentKeys.user: inherited[EnvironmentKeys.user] ?? "leverage-e2e",
            EnvironmentKeys.apiURL: EndToEnd.apiURL.absoluteString,
            EnvironmentKeys.helperToken: token,
            EnvironmentKeys.supportDir: folder.support.path,
            EnvironmentKeys.runnerPath: try EndToEnd.program("LeverageRunner").path,
        ]
        if let tools {
            environment[EnvironmentKeys.path] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment[EnvironmentKeys.home] = try folder.folder("home").path
            environment[EnvironmentKeys.toolDir] = tools.bin.path
            environment[EnvironmentKeys.tokenStore] = "memory"
            if let providerAPIBase {
                environment[EnvironmentKeys.providerAPIBase] = providerAPIBase.absoluteString
                environment[EnvironmentKeys.readTimeoutSeconds] = "2"
            }
        } else {
            environment[EnvironmentKeys.path] = inherited[EnvironmentKeys.path] ?? "/usr/bin:/bin"
            environment[EnvironmentKeys.home] = inherited[EnvironmentKeys.home] ?? NSHomeDirectory()
        }
        if let tmp = inherited[EnvironmentKeys.tmpdir] { environment[EnvironmentKeys.tmpdir] = tmp }
        logFile = folder.logs.appendingPathComponent("helper.log")
        process = try Self.launch(SubprocessRequest(
            executable: try EndToEnd.program("LeverageHelper").path,
            arguments: [],
            environment: environment,
            gracePeriod: .seconds(20)))
    }

    static func launch(_ request: SubprocessRequest) throws -> RunningSubprocess {
        try Subprocess.startSession(request)
    }

    func send(_ message: LocalHelperMessage) async throws {
        try await process.writeLine(message.encodeLine())
    }

    /// Stops the helper (it stops its runs first) and keeps what it wrote
    /// to standard error in `logs/helper.log`, as the app does.
    @discardableResult
    func stop() async -> SubprocessResult {
        process.stop()
        let result = await process.wait()
        try? (result.standardOutput + result.standardError).write(to: logFile)
        return result
    }
}

/// Runs `body`, then `cleanup` whether or not `body` threw.
func withCleanup<T>(
    _ body: () async throws -> T, cleanup: () async -> Void
) async throws -> T {
    do {
        let value = try await body()
        await cleanup()
        return value
    } catch {
        await cleanup()
        throw error
    }
}

// MARK: - Waits

/// Reads the owner's log by long polls (`list_events` with `wait`).
actor EventFollower {
    let owner: OwnerClient
    private(set) var seen: [EventRecord] = []
    private var afterSeq: Int

    init(owner: OwnerClient, afterSeq: Int = 0) {
        self.owner = owner
        self.afterSeq = afterSeq
    }

    /// Starts after every event already in the log.
    static func fromNow(owner: OwnerClient) async throws -> EventFollower {
        var after = 0
        while true {
            let page = try await owner.events(afterSeq: after, limit: 500, wait: nil)
            if page.events.isEmpty { return EventFollower(owner: owner, afterSeq: after) }
            after = page.nextAfterSeq
        }
    }

    /// The first event, already seen or still to come, that matches; fails
    /// when `deadline` passes first or when `failing` matches one.
    func wait(
        for what: String, deadline seconds: Double,
        failing: (@Sendable (EventRecord) -> Bool)? = nil,
        where matches: @Sendable (EventRecord) -> Bool
    ) async throws -> EventRecord {
        let deadline = Date().addingTimeInterval(seconds)
        var looked = 0
        while true {
            for event in seen[looked...] {
                if let failing, failing(event) {
                    throw EndToEndFailure("while waiting for \(what): \(event.type.rawValue) at seq \(event.seq)")
                }
                if matches(event) { return event }
            }
            looked = seen.count
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw EndToEndFailure("\(what) did not happen within \(Int(seconds)) s") }
            let page = try await owner.events(afterSeq: afterSeq, limit: 500, wait: min(20, max(1, Int(left))))
            seen.append(contentsOf: page.events)
            afterSeq = page.nextAfterSeq
        }
    }

    func events(of task: UUID) -> [EventRecord] {
        seen.filter { $0.taskID == task }.sorted { $0.seq < $1.seq }
    }
}

/// Follows a helper request by long polls until it is finished or failed.
func finishedRequest(_ id: UUID, owner: OwnerClient, deadline seconds: Double) async throws -> HelperRequest {
    let deadline = Date().addingTimeInterval(seconds)
    var changedAfter: Date?
    while true {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw EndToEndFailure("helper request \(id.contractString) did not finish in time") }
        let request = try await owner.helperRequest(
            id: id, wait: min(20, max(1, Int(left))), changedAfter: changedAfter).request
        if [.finished, .failed].contains(request.state) { return request }
        changedAfter = request.updatedAt
    }
}

/// Looks at a state the API has no long poll for, every quarter second,
/// until it holds or `deadline` passes.
func eventually(
    _ what: String, deadline seconds: Double, _ holds: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while try await !holds() {
        guard Date() < deadline else { throw EndToEndFailure("\(what): not within \(Int(seconds)) s") }
        try await Task.sleep(for: .milliseconds(250))
    }
}

// MARK: - The owner's steps

extension OwnerClient {
    /// Add credential for a login, then the helper's checks: the stand-in
    /// starts signed out, the helper opens its sign-in and goes on by
    /// itself (L714, L716). Returns the credential's id. `id` lets a test
    /// know the login's account folder before it is added; `model` and
    /// `strengthRank` are what the app sends (milestone 3 plan HE-5).
    func addLogin(
        _ provider: Provider, name: String, id: UUID = UUID(), model: String? = nil, strengthRank: Int? = nil,
        deadline: Double = 120
    ) async throws -> UUID {
        let outcome = try await addCredential(
            AddCredentialRequest(
                credentialID: id, provider: provider, name: name, model: model, strengthRank: strengthRank),
            key: IdempotencyKey())
        guard let added = try outcome.completedResult() else {
            throw EndToEndFailure("add_credential answered no request")
        }
        let request = try await finishedRequest(added.helperRequestID, owner: self, deadline: deadline)
        guard request.state == .finished, request.result?.outcome == .finished else {
            throw EndToEndFailure("the checks of \(name) did not pass: \(String(describing: request.result))")
        }
        return id
    }

    /// Verify (`verify_credential`) or Sign in again (`sign_in_again`) for
    /// one login, followed to the helper's end. Returns the ended request;
    /// throws when it did not end as `expected` (a Verify that finds the
    /// login signed out fails, and that failure is what writes
    /// `credential.signed_out`).
    func followed(
        _ what: String, _ outcome: PlainOutcome, expected: HelperRequestState = .finished, deadline: Double = 120
    ) async throws -> HelperRequest {
        _ = try outcome.completedResult()
        guard let id = outcome.helperRequestID else { throw EndToEndFailure("\(what) answered no helper request") }
        let request = try await finishedRequest(id, owner: self, deadline: deadline)
        guard request.state == expected else {
            throw EndToEndFailure("\(what) ended \(request.state.rawValue): \(String(describing: request.result))")
        }
        return request
    }

    /// Milestone 4 plan RT-2: the tests of milestones 2 and 3 keep proving
    /// the loop and handoff with no rule in the way. Creating the owner now
    /// writes the seven shipped rules, on; this sends `disable_rule` for each
    /// of them that is on, and leaves one that is off alone, so a second
    /// class signed in to the same owner changes nothing. It is called once
    /// the owner exists, never inside `EndToEnd.owner()`, which the
    /// rule-check tests share. Returns how many it turned off.
    @discardableResult
    func turnShippedRulesOff() async throws -> Int {
        let shipped = try await listRules().rules.filter { $0.version.origin == .shipped }
        guard shipped.count == 7 else {
            throw EndToEndFailure("the owner has \(shipped.count) shipped rules, not the seven")
        }
        var turnedOff = 0
        for row in shipped where row.rule.enabled {
            _ = try await disableRule(ruleID: row.rule.id, key: IdempotencyKey()).completedResult()
            turnedOff += 1
        }
        let after = try await listRules().rules.filter { $0.version.origin == .shipped }
        guard after.allSatisfy({ !$0.rule.enabled }) else {
            throw EndToEndFailure("a shipped rule is still on after disable_rule")
        }
        return turnedOff
    }

    func connect(_ name: String, role: SeatRole, login: UUID) async throws -> UUID {
        let outcome = try await connectSeat(
            ConnectSeatRequest(name: name, role: role, credentialID: login), key: IdempotencyKey())
        guard let seat = try outcome.completedResult() else {
            throw EndToEndFailure("connect_seat answered no seat")
        }
        return seat.seatID
    }

    func connectByPrompt(
        _ name: String, role: SeatRole, provider: Provider, connection: LandingPromptConnection = .http
    ) async throws -> LandingPromptIssued {
        let outcome = try await connectSeat(
            ConnectSeatRequest(name: name, role: role, provider: provider), key: IdempotencyKey())
        guard let seat = try outcome.completedResult() else {
            throw EndToEndFailure("connect_seat answered no seat")
        }
        return try await newPrompt(seat: seat.seatID, connection: connection)
    }

    func newPrompt(seat: UUID, connection: LandingPromptConnection = .http) async throws -> LandingPromptIssued {
        let outcome = try await issueLandingPrompt(seatID: seat, connection: connection, key: IdempotencyKey())
        guard case .shown(let prompt)? = try outcome.completedResult(),
              prompt.seatID == seat, prompt.connection == connection else {
            throw EndToEndFailure("issue_landing_prompt did not issue a fresh prompt for the seat")
        }
        return prompt
    }

    /// Stop for a seat the app runs: waits until the helper has done it and
    /// the server has the run as stopped.
    func stopAndWait(seat: UUID) async throws {
        let outcome = try await stopSeat(seatID: seat, key: IdempotencyKey())
        _ = try outcome.completedResult()
        if let request = outcome.helperRequestID {
            let done = try await finishedRequest(request, owner: self, deadline: Patience.seconds(60))
            guard done.state == .finished else {
                throw EndToEndFailure("the stop of seat \(seat.contractString) failed")
            }
        }
        try await eventually("seat \(seat.contractString) stopped", deadline: Patience.seconds(30)) {
            try await self.seats().seats.first { $0.id == seat }?.runState == .stopped
        }
    }

    func waitUntilRunning(_ seats: [UUID]) async throws {
        try await eventually("the seats' runs started", deadline: Patience.seconds(60)) {
            let listed = try await self.seats().seats
            return seats.allSatisfy { id in listed.first { $0.id == id }?.runState == .running }
        }
    }

    /// Add task, then Complete contract with the build criteria given and
    /// the review criterion the form adds (IN-20). Returns the task's id
    /// and the two commands' keys.
    func addReadyTask(title: String, criteria: [String], folder: URL) async throws
        -> (task: UUID, addKey: IdempotencyKey, contractKey: IdempotencyKey) {
        let goal = "The end-to-end run reaches Done."
        let addKey = IdempotencyKey()
        let added = try await addTask(
            AddTaskRequest(title: title, goal: goal, priority: .normal, workReference: folder.path, state: .backlog),
            key: addKey)
        guard let task = try added.completedResult()?.taskID else {
            throw EndToEndFailure("add_task answered no task")
        }
        let contractKey = IdempotencyKey()
        let contract = CompleteContractRequest(
            title: title, goal: goal, details: "Made by the end-to-end run.",
            criteria: criteria.map { CriterionInput(text: $0) }
                + [CriterionInput(text: "An independent reviewer agrees.", kind: .review)],
            workReference: folder.path)
        _ = try await completeContract(taskID: task, contract, key: contractKey).completedResult()
        return (task, addKey, contractKey)
    }
}

// MARK: - Processes

enum Processes {
    struct Entry: Equatable {
        let pid: Int32
        let parent: Int32
        let command: String
    }

    /// Every process on the machine, from `ps`.
    static func all() async throws -> [Entry] {
        let ps = ["/bin/ps", "/usr/bin/ps"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/ps"
        let result = try await Subprocess.run(SubprocessRequest(
            executable: ps, arguments: ["-A", "-ww", "-o", "pid=", "-o", "ppid=", "-o", "command="],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "C"], timeLimit: .seconds(30)))
        guard result.succeeded else { throw EndToEndFailure("ps failed") }
        return String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: fields.count > 2 ? String(fields[2]) : "")
        }
    }

    /// The processes below `root`, and any whose command line names a path
    /// inside `folder` (a stand-in tool left behind by a run would).
    static func startedBy(_ root: Int32, orNaming folder: URL) async throws -> [Entry] {
        let entries = try await all()
        var below: Set<Int32> = [root]
        var grew = true
        while grew {
            grew = false
            for entry in entries where below.contains(entry.parent) && !below.contains(entry.pid) {
                below.insert(entry.pid)
                grew = true
            }
        }
        let own = getpid()
        return entries.filter { entry in
            entry.pid != root && entry.pid != own
                && (below.contains(entry.pid) || entry.command.contains(folder.path))
                && !entry.command.hasPrefix("ps ") && !entry.command.contains("/ps -A")
        }
    }
}

// MARK: - Trace 09

/// The golden trace the core loop follows, read from the contract.
enum Trace09 {
    /// Each command's name and the types of the events it writes, in order.
    static func commands() throws -> [(command: String, events: [String])] {
        let file = EndToEnd.repositoryRoot.appendingPathComponent("api/contract/traces/09-core-loop-no-rules.json")
        let trace = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard let commands = trace?["commands"] as? [[String: Any]] else {
            throw EndToEndFailure("trace 09 has no commands")
        }
        return try commands.map { command in
            guard let name = command["command"] as? String,
                  let expect = command["expect"] as? [String: Any],
                  let events = expect["events"] as? [[String: Any]] else {
                throw EndToEndFailure("a command of trace 09 has no name or events")
            }
            return (name, events.compactMap { $0["type"] as? String })
        }
    }
}

/// The task's events cut where `command_id` changes: one group per command.
func groupedByCommand(_ events: [EventRecord]) -> [(key: String?, events: [EventRecord])] {
    var groups: [(key: String?, events: [EventRecord])] = []
    for event in events {
        if let last = groups.last, last.key == event.commandID {
            groups[groups.count - 1].events.append(event)
        } else {
            groups.append((event.commandID, [event]))
        }
    }
    return groups
}
