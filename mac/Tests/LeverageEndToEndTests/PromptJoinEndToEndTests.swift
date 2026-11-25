import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

extension LeverageEndToEnd {
    @Suite("A prompt-connected General agent")
    struct PromptJoinEndToEndTests {
        @Test("the short prompt leads to Done and Remove ends the agent's session")
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
                    title: "Remove releases the lease", criteria: ["criterion-2.txt exists."], folder: work).task
                let held = try await agent.claimTask()
                try #require(held.task.id == second && held.lease.seatID == prompt.seatID)
                _ = try await owner.removeSeat(seatID: prompt.seatID, key: IdempotencyKey()).completedResult()
                let stopped = try await agent.stopsAfterRevocation()
                try #require(stopped, "the old agent did not receive HTTP 401 at its next poll")
                let page = try await owner.task(id: second)
                #expect(page.task.state == .ready && page.task.holderSeatID == nil)
                #expect(page.events.contains { $0.type == .taskReleased && $0.string("reason") == "seat_removed" })
                _ = try await owner.cancelTask(taskID: second, key: IdempotencyKey()).completedResult()
                try await owner.stopAndWait(seat: reviewer)
            } cleanup: {
                await helper.stop()
            }
        }
    }

    @Suite("Prompt agent model and permissions")
    struct PromptAgentSettingsEndToEndTests {
        @Test("a Prompt agent reports its model and effort to the roster")
        func promptReportsModel() async throws {
            let folder = try TestFolder("prompt-reports-model")
            let owner = try await setup(in: folder)
            let (agent, seatID) = try await connectPrompt(
                "Reporting agent", owner: owner, folder: folder, provider: .claude)
            let before = try #require(try await owner.seats().seats.first { $0.id == seatID })
            #expect(before.model == nil && before.effort == nil)

            let model = "claude-sonnet-5-5"
            let effort = "high"
            let report = try await agent.client.reportModel(
                ReportModelRequest(model: model, effort: effort), key: IdempotencyKey())
            #expect(try report.completedResult() == ReportedModel(model: model, effort: effort))
            let after = try #require(try await owner.seats().seats.first { $0.id == seatID })
            #expect(after.model == model && after.effort == effort)
            _ = try await owner.removeSeat(seatID: seatID, key: IdempotencyKey()).completedResult()
        }

        @Test("a Prompt agent with Create adds a Ready task with the seat as actor")
        func promptCreatesReadyTask() async throws {
            let folder = try TestFolder("prompt-creates-task")
            let owner = try await setup(in: folder)
            let permissions = SeatPermissions(work: false, deliver: false, create: true)
            let (agent, seatID) = try await connectPrompt(
                "Creating agent", owner: owner, folder: folder, permissions: permissions)
            let work = try folder.folder("work")
            let request = CreateTaskRequest(
                title: "Check the example file", details: "Write the example file and have a reviewer check it.",
                criteria: [
                    CriterionInput(text: "example.txt exists."),
                    CriterionInput(text: "An independent reviewer confirms that example.txt contains one line.", kind: .review),
                ],
                workReference: work.path)
            let key = IdempotencyKey()
            let outcome = try await agent.client.createTask(request, key: key)
            let created = try #require(try outcome.completedResult())
            #expect(created.state == .ready)

            let page = try await owner.task(id: created.taskID)
            #expect(page.task.state == .ready && page.task.title == request.title)
            let creation = try #require(page.events.first { $0.type == .taskCreated })
            #expect(creation.actorKind == .seat && creation.actorID == seatID && creation.commandID == key.value)
            _ = try await owner.cancelTask(taskID: created.taskID, key: IdempotencyKey()).completedResult()
            _ = try await owner.removeSeat(seatID: seatID, key: IdempotencyKey()).completedResult()
        }

        @Test("a Ready task is offered to the Deliver-on agent after the Deliver-off agent gets no offer")
        func deliverOffGetsNoTaskOffer() async throws {
            let folder = try TestFolder("deliver-off-no-offer")
            let owner = try await setup(in: folder)
            let (deliverOff, offSeat) = try await connectPrompt(
                "Deliver off", owner: owner, folder: folder, permissions: SeatPermissions(deliver: false))
            let (deliverOn, onSeat) = try await connectPrompt("Deliver on", owner: owner, folder: folder)
            let work = try folder.folder("work")
            let task = try await owner.addReadyTask(
                title: "Offer to the agent with Deliver on", criteria: ["example.txt exists."], folder: work).task
            try #require(try await owner.task(id: task).task.state == .ready)

            #expect(try await deliverOff.client.next(wait: 0).kind == .none)
            try #require(try await deliverOn.client.next(wait: 0).kind == .task)
            let claim = try #require(try await deliverOn.client.claimNextTask(key: IdempotencyKey()).completedResult())
            #expect(claim.task.id == task && claim.lease.seatID == onSeat)
            _ = try await owner.cancelTask(taskID: task, key: IdempotencyKey()).completedResult()
            _ = try await owner.removeSeat(seatID: offSeat, key: IdempotencyKey()).completedResult()
            _ = try await owner.removeSeat(seatID: onSeat, key: IdempotencyKey()).completedResult()
        }

        @Test("turning Deliver off gives back the Working task and its heartbeat answers not_holder")
        func deliverOffReleasesWorkingTask() async throws {
            let folder = try TestFolder("deliver-off-releases-task")
            let owner = try await setup(in: folder)
            let (agent, seatID) = try await connectPrompt("Holding agent", owner: owner, folder: folder)
            let work = try folder.folder("work")
            let task = try await owner.addReadyTask(
                title: "Give this task back when Deliver turns off", criteria: ["example.txt exists."], folder: work).task
            let claim = try await agent.claimTask()
            try #require(claim.task.id == task && claim.lease.seatID == seatID)
            try #require(try await owner.task(id: task).task.state == .working)

            _ = try await owner.changeSeat(
                seatID: seatID, ChangeSeatRequest(permissions: SeatPermissions(deliver: false)),
                key: IdempotencyKey()).completedResult()
            let page = try await owner.task(id: task)
            #expect(page.task.state == .ready && page.task.holderSeatID == nil)
            #expect(page.events.contains { $0.type == .taskReleased && $0.string("reason") == "deliver_turned_off" })
            let heartbeat = try await agent.client.heartbeatTask(taskID: task, key: IdempotencyKey())
            #expect(heartbeat.outcome == .refused && heartbeat.refusal?.code == .notHolder)
            _ = try await owner.cancelTask(taskID: task, key: IdempotencyKey()).completedResult()
            _ = try await owner.removeSeat(seatID: seatID, key: IdempotencyKey()).completedResult()
        }

        private func setup(in folder: TestFolder) async throws -> OwnerClient {
            let owner = try await EndToEnd.owner()
            try await owner.turnShippedRulesOff()
            try folder.record(secrets: [EndToEnd.ownerPassword, owner.transport.token ?? ""].filter { !$0.isEmpty })
            return owner
        }

        private func connectPrompt(
            _ name: String, owner: OwnerClient, folder: TestFolder,
            provider: Provider = .codex, permissions: SeatPermissions? = nil
        ) async throws -> (agent: PromptStandInAgent, seatID: UUID) {
            let prompt = try await owner.connectByPrompt(name, role: .general, provider: provider, permissions: permissions)
            try folder.record(secrets: [prompt.seatToken, prompt.text])
            let agent = try PromptStandInAgent(landingPrompt: prompt.text)
            try await agent.readInstructions()
            return (agent, prompt.seatID)
        }
    }
}

/// This stand-in starts with only the text a user can paste into an agent.
private struct PromptStandInAgent {
    let client: any AgentAPI

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
