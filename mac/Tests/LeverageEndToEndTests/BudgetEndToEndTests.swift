import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@Suite(.enabled(if: questionsApprovalsEnabled), .timeLimit(.minutes(Patience.minutes(8))))
struct BudgetEndToEndTests {
    @Test func testProjectPausesAtItsBudget() async throws {
        try await withQuestionsApprovalsWorld("project-budget") { world in
            let createKey = IdempotencyKey()
            _ = try await world.owner.createProject(
                CreateProjectRequest(name: "Sample project", budget: 1), key: createKey).completedResult()
            let created = try await world.waitFor("project.created") {
                $0.type == .projectCreated && $0.commandID == createKey.value
            }
            let project = try #require(created.projectID)
            let brief = "Use the samples in \(world.marker("brief"))."
            let briefKey = IdempotencyKey()
            _ = try await world.owner.editBrief(
                projectID: project, EditBriefRequest(entries: [BriefEntryInput(kind: .rule, text: brief)]),
                key: briefKey).completedResult()
            _ = try await world.waitFor("brief.changed") {
                $0.type == .briefChanged && $0.projectID == project && $0.commandID == briefKey.value
            }

            let (seat, builder, _) = try await world.manualBuilder()
            let (_, otherBuilder, _) = try await world.manualBuilder("Second builder")
            let task = try await world.addTask(title: "Prepare the first sample", projectID: project).task
            let claim = try await claimManualTask(task, seat: seat, builder: builder, world: world)
            let expectedBrief = claim.briefing.brief.map(\.text) == [brief]
            #expect(expectedBrief, "the project brief reached the builder")
            let otherTask = try await world.addTask(title: "Prepare the second sample", projectID: project).task
            _ = try await world.waitFor("the second task is ready", task: otherTask) {
                $0.type == .taskReady && $0.taskID == otherTask
            }
            #expect(try await otherBuilder.next(wait: 0).kind == .task)

            try await requestAndGrantAccess(task, builder: builder, world: world)
            let firstCostKey = IdempotencyKey()
            _ = try await builder.reportCost(
                taskID: task, ReportCostRequest(tokens: 60, spend: Decimal(6) / 10), key: firstCostKey).completedResult()
            let belowBudget = try await listedProject(project, world: world)
            #expect(belowBudget.spent == Decimal(6) / 10)
            #expect(!belowBudget.paused)
            #expect(try await otherBuilder.next(wait: 0).kind == .task)

            let secondCostKey = IdempotencyKey()
            _ = try await builder.reportCost(
                taskID: task, ReportCostRequest(tokens: 50, spend: Decimal(5) / 10), key: secondCostKey).completedResult()
            let opened = try await world.waitFor("the project budget item in Needs you") {
                $0.type == .inboxOpened && $0.projectID == project
                    && $0.payload["kind"]?.stringValue == "project_budget_reached"
            }
            let paused = try await listedProject(project, world: world)
            #expect(paused.paused)
            #expect(paused.pausedBy == .budget)
            #expect(paused.spent == Decimal(11) / 10)

            let inbox = try await world.owner.listInbox(afterSeq: nil, wait: nil)
            let budgetItems = inbox.items.filter { $0.kind == .projectBudgetReached }
            guard budgetItems.count == 1, let item = budgetItems.first else {
                throw EndToEndFailure("Needs you did not list exactly one project budget item")
            }
            #expect(item.id == opened.subjectID)
            #expect(item.aboutID == project)
            #expect(item.aboutKind == .project)
            #expect(item.choices == [.changeBudget, .resumeProject])
            let firstHold = try await openProjectHold(task, world: world)
            let secondHold = try await openProjectHold(otherTask, world: world)
            #expect(firstHold.projectID == project && secondHold.projectID == project)

            let refusedKey = IdempotencyKey()
            let refused = try await otherBuilder.claimNextTask(key: refusedKey)
            #expect(refused.outcome == .refused)
            #expect(refused.refusal?.code == .notEligible)

            let budgetKey = IdempotencyKey()
            _ = try await world.owner.changeBudget(
                projectID: project, ChangeBudgetRequest(budget: 5), key: budgetKey).completedResult()
            let openInbox = try await world.owner.listInbox(afterSeq: nil, wait: nil)
            let stillOpen = openInbox.items.contains { $0.id == item.id }
            #expect(!stillOpen)
            try await resumeManualTask(task, builder: builder, world: world)
            try await finishManualTask(task, builder: builder, world: world)
            let final = try await listedProject(project, world: world)
            #expect(final.budget == 5)
            #expect(final.spent == Decimal(11) / 10)
            #expect(!final.paused)

            let events = try await world.wholeLog().filter { $0.projectID == project }
            try questionsApprovalsOrder(events, [
                .type(.costReported) {
                    $0.commandID == firstCostKey.value && $0.taskID == task && $0.actorID == seat
                        && $0.payload["spend"]?.numberValue == 0.60
                },
                .type(.costReported) {
                    $0.commandID == secondCostKey.value && $0.taskID == task && $0.actorID == seat
                        && $0.payload["spend"]?.numberValue == 0.50
                },
                .type(.checkFinished) {
                    $0.commandID == secondCostKey.value && $0.payload["result"]?.stringValue == "applied"
                        && $0.payload["effect"]?.stringValue == "project_paused"
                },
                .type(.projectPaused) { $0.commandID == secondCostKey.value && $0.actorKind == .app },
                .type(.holdOpened) {
                    $0.commandID == secondCostKey.value && $0.taskID == task && $0.subjectID == firstHold.id
                        && $0.payload["reason"]?.stringValue == "project_paused"
                },
                .type(.holdOpened) {
                    $0.commandID == secondCostKey.value && $0.taskID == otherTask && $0.subjectID == secondHold.id
                        && $0.payload["reason"]?.stringValue == "project_paused"
                },
                .type(.inboxOpened) { $0.commandID == secondCostKey.value && $0.subjectID == item.id },
                .type(.projectBudgetChanged) {
                    $0.commandID == budgetKey.value && $0.payload["budget"]?.numberValue == 5
                },
                .type(.projectResumed) { $0.commandID == budgetKey.value && $0.actorKind == .owner },
                .type(.holdClosed) { $0.commandID == budgetKey.value && $0.subjectID == firstHold.id },
                .type(.holdClosed) { $0.commandID == budgetKey.value && $0.subjectID == secondHold.id },
                .type(.inboxResolved) {
                    $0.commandID == budgetKey.value && $0.subjectID == item.id
                        && $0.payload["choice"]?.stringValue == "change_budget"
                },
                .type(.taskDone) { $0.taskID == task }
            ])
            let refusedClaimWroteEvents = events.contains { $0.commandID == refusedKey.value }
            #expect(!refusedClaimWroteEvents)
        }
    }

    private func listedProject(_ id: UUID, world: QuestionsApprovalsWorld) async throws -> Project {
        let projects = try await world.owner.listProjects()
        guard let project = projects.projects.first(where: { $0.id == id }) else {
            throw EndToEndFailure("List projects did not return the budgeted project")
        }
        return project
    }

    private func openProjectHold(_ task: UUID, world: QuestionsApprovalsWorld) async throws -> Hold {
        let page = try await world.owner.task(id: task)
        return try #require(page.holds.first { $0.reason == .projectPaused && $0.closedAt == nil })
    }

    private func requestAndGrantAccess(
        _ task: UUID, builder: AgentClient, world: QuestionsApprovalsWorld
    ) async throws {
        let description = "Please grant access to \(world.marker("access"))."
        let accessKey = IdempotencyKey()
        _ = try await builder.requestAccess(
            taskID: task, RequestAccessRequest(description: description), key: accessKey).completedResult()
        let opened = try await world.waitFor("the access request in Needs you", task: task) {
            $0.type == .inboxOpened && $0.taskID == task && $0.commandID == accessKey.value
        }
        let inbox = try await world.owner.listInbox(afterSeq: nil, wait: nil)
        guard let item = inbox.items.first(where: { $0.id == opened.subjectID }) else {
            throw EndToEndFailure("Needs you did not return the access item after it opened")
        }
        #expect(item.kind == .accessRequest)
        #expect(item.aboutID == task)
        let hasNoFacts = item.facts.isEmpty
        #expect(hasNoFacts, "the access item contains no facts")
        let expectedDetail = item.detail == description
        #expect(expectedDetail, "Needs you returned the access request")
        let grantKey = IdempotencyKey()
        _ = try await world.owner.grantAccess(taskID: task, key: grantKey).completedResult()
        try await resumeManualTask(task, builder: builder, world: world)
        let events = try await world.owner.task(id: task).events
        try questionsApprovalsOrder(events, [
            .type(.holdOpened) { $0.commandID == accessKey.value && $0.subjectID == item.holdID },
            .type(.inboxOpened) { $0.commandID == accessKey.value && $0.subjectID == item.id },
            .type(.holdClosed) { $0.commandID == grantKey.value && $0.subjectID == item.holdID },
            .type(.inboxResolved) { $0.commandID == grantKey.value && $0.subjectID == item.id }
        ])
    }
}
