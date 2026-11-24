import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

extension LeverageEndToEnd {
    @Suite("A prompt-connected General agent")
    struct PromptJoinEndToEndTests {
        @Test("the short prompt leads to Done and New prompt ends the agent's session")
        func testShortPromptAgentTakesTaskToDone() async throws {
            let folder = try TestFolder("short-prompt")
            let tools = try StandIns.copy(into: folder.url)
            let work = try folder.folder("work")
            let owner = try await EndToEnd.owner()
            try await owner.turnShippedRulesOff()
            guard let helperToken = try await owner.issueHelperToken(
                name: "End-to-end Mac", idempotencyKey: IdempotencyKey().value
            ) else { throw EndToEndFailure("issue_helper_token answered no token") }
            try folder.record(secrets: [
                EndToEnd.ownerPassword, owner.transport.token ?? "", helperToken,
                StandIns.statusEmail, StandIns.statusOrganisation,
            ].filter { !$0.isEmpty })
            let follower = try await EventFollower.fromNow(owner: owner)
            let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools)

            try await withCleanup {
                let claude = try await owner.addLogin(.claude, name: "Claude (prompt reviewer)", deadline: Patience.seconds(120))
                let reviewer = try await owner.connect("Prompt task reviewer", role: .reviewer, login: claude)
                try await owner.waitUntilRunning([reviewer])
                let prompt = try await owner.connectByPrompt("Prompt General", role: .general, provider: .codex)
                try folder.record(secrets: [prompt.seatToken, prompt.text])
                let agent = try PromptStandInAgent(landingPrompt: prompt.text)
                try await agent.readInstructions()

                let first = try await owner.addReadyTask(
                    title: "Prompt-connected agent builds", criteria: ["criterion-1.txt exists."], folder: work).task
                let claimed = try await agent.claimTask()
                try #require(claimed.task.id == first && claimed.lease.seatID == prompt.seatID)
                try await agent.submit(claimed, work: work)
                _ = try await follower.wait(for: "the prompt agent's task is Done", deadline: Patience.seconds(120)) {
                    $0.taskID == first && $0.type == .taskDone
                }
                try inOrder(await follower.events(of: first), [
                    .type(.taskClaimed) { $0.actorID == prompt.seatID },
                    .type(.taskBriefingAcknowledged) { $0.actorID == prompt.seatID },
                    .type(.criterionPassed) { $0.actorID == prompt.seatID },
                    .type(.taskSubmitted) { $0.actorID == prompt.seatID },
                    .type(.reviewStarted) { $0.actorID == reviewer },
                    .type(.reviewPassed) { $0.actorID == reviewer },
                    .type(.taskDone),
                ])
                #expect(try await owner.task(id: first).task.state == .done)

                let second = try await owner.addReadyTask(
                    title: "New prompt releases the lease", criteria: ["criterion-2.txt exists."], folder: work).task
                let held = try await agent.claimTask()
                try #require(held.task.id == second && held.lease.seatID == prompt.seatID)
                let replacement = try await owner.newPrompt(seat: prompt.seatID)
                try folder.record(secrets: [replacement.seatToken, replacement.text])
                let stopped = try await agent.stopsAfterRevocation()
                try #require(stopped, "the old agent did not receive HTTP 401 at its next poll")
                let page = try await owner.task(id: second)
                #expect(page.task.state == .ready && page.task.holderSeatID == nil)
                #expect(page.events.contains { $0.type == .taskReleased && $0.string("reason") == "new_prompt" })
                try await owner.stopAndWait(seat: reviewer)
            } cleanup: {
                await helper.stop()
            }
        }
    }
}

/// This stand-in starts with only the text a user can paste into an agent.
private struct PromptStandInAgent {
    private let client: AgentClient

    init(landingPrompt: String) throws {
        guard let fields = landingPrompt.wholeMatch(of: #/Join Leverage at (https?://\S+) with token ([A-Za-z0-9_-]+)\. Fetch GET (\S+) with header Authorization: Bearer ([A-Za-z0-9_-]+) and follow its instructions exactly\./#),
              let address = URL(string: String(fields.1)),
              fields.3 == "\(fields.1)/v1/join", fields.2 == fields.4 else {
            throw EndToEndFailure("the agent did not receive a one-line HTTP landing prompt")
        }
        client = AgentClient(baseURL: address, seatToken: String(fields.2))
    }

    func readInstructions() async throws {
        let join = try await client.join()
        #expect(join.role == .general && join.connection == .http)
        let keepsPolling = join.text.contains("Ask `GET /v1/next?wait=30` again as soon as it answers.")
        let stopsOn401 = join.text.contains("If any call answers 401") && join.text.contains("Stop at once")
        let namesRoleFile = join.text.lowercased().contains("role file")
        let hasJobRules = SeatRole.general.jobRules.allSatisfy { join.text.contains($0) }
        try #require(keepsPolling && stopsOn401 && !namesRoleFile && hasJobRules, "incorrect General join guidance")
    }

    func claimTask() async throws -> TaskClaim {
        let deadline = ContinuousClock.now + Patience.scaled(.seconds(120))
        repeat {
            let offer = try await client.next(wait: 30)
            if offer.kind == .task {
                let claim = try await client.claimNextTask(key: IdempotencyKey()).completedResult()
                return try #require(claim, "the agent was offered a task but did not claim it")
            }
            try #require(offer.kind == .none)
        } while ContinuousClock.now < deadline
        throw EndToEndFailure("the agent was not offered a task before its deadline")
    }

    func submit(_ claim: TaskClaim, work: URL) async throws {
        let task = claim.task.id
        let briefing = try await client.taskBriefing(taskID: task).briefing
        #expect(briefing.roleFile == nil)
        _ = try await client.acknowledgeTaskBriefing(
            taskID: task, briefingHash: briefing.hash, key: IdempotencyKey()).completedResult()
        let criteria = briefing.contract.criteria.filter { $0.kind == .build }
        try #require(criteria.count == 1)
        for criterion in criteria {
            _ = try await client.startCriterion(taskID: task, criterionID: criterion.id, key: IdempotencyKey()).completedResult()
            try Data("ready\n".utf8).write(to: work.appendingPathComponent("criterion-1.txt"))
            _ = try await client.passCriterion(
                taskID: task, criterionID: criterion.id, evidence: .init(kind: .note, value: "criterion-1.txt"),
                key: IdempotencyKey()).completedResult()
        }
        _ = try await client.submitTask(
            taskID: task, .init(handoffNote: "The criterion file is ready.", workReference: work.path),
            key: IdempotencyKey()).completedResult()
    }

    func stopsAfterRevocation() async throws -> Bool {
        do {
            _ = try await client.next(wait: 30)
            return false
        } catch let error as TransportError where error.status == 401 {
            return true
        }
    }
}
