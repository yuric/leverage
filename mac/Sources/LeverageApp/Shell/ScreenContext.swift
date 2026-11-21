import Foundation
import LeverageKit
import Observation

/// Where the owner is in the window.
@MainActor
@Observable
final class Navigator {
    enum Place: Equatable, Sendable {
        case board, needsYou, decided, activity, agents, credentials, handoff, settings, projects
    }

    private(set) var place: Place = .board
    /// Shared by the pane, the Board and the Add task sheet.
    var boardFilter = BoardFilter()
    /// The task whose page is open in the content area (MA-9); nil shows the
    /// screen of `place`.
    private(set) var openTaskID: UUID?
    /// Whether the Add task sheet is showing. The shell presents it.
    var isAddTaskPresented = false
    /// The task whose page was opened to change it; its page takes the
    /// request once. Not observed: taking it changes nothing on screen.
    @ObservationIgnored private var editRequest: UUID?

    /// Shows a tab's screen.
    func show(_ place: Place) {
        self.place = place
        openTaskID = nil
        editRequest = nil
    }

    /// Opens the Board scoped to this project, or to All projects for nil.
    func selectProject(_ id: UUID?) {
        boardFilter.projectID = id
        show(.board)
    }

    /// Opens a task's page, with a way back to the board (MA-9). `editing`
    /// asks the page to open the contract editor once it has read the task
    /// (Needs you's Change the task, HM-24, HM-49).
    func open(task id: UUID, editing: Bool = false) {
        place = .board
        openTaskID = id
        editRequest = editing ? id : nil
    }

    /// Whether the page of `id` was opened to change the task; true once.
    func takeEditRequest(for id: UUID) -> Bool {
        guard editRequest == id else { return false }
        editRequest = nil
        return true
    }

    /// Back to the board from a task's page.
    func closeTask() {
        openTaskID = nil
        editRequest = nil
    }

    func presentAddTask() { isAddTaskPresented = true }

    /// After Add task saved: the sheet closes and the board shows.
    func finishAddTask() {
        isAddTaskPresented = false
        show(.board)
    }
}

/// What every screen of the content area needs, in the SwiftUI environment:
///
///     @Environment(ScreenContext.self) private var context
///
/// The shell builds each screen with no arguments and gives it its
/// context this way, so a screen's own files never need
/// the shell to change. A screen builds its view model from `owner` when it
/// appears, tells `feed` where each of its reads stood (`noteRead`), reads
/// again when `feed` reports events, and uses `navigator` to open a task or
/// come back to the board.
///
/// `owner` already returns the app to the sign-in screen when any call of it
/// answers 401 (MA-6): a view model still sees the error and shows its own
/// signed-out state, and does nothing more about it.
@MainActor
@Observable
final class ScreenContext {
    let owner: any OwnerAPI
    let feed: EventFeed
    let health: HealthLineModel
    let navigator: Navigator
    let runtime: any AppRuntime
    /// Counts the open Needs you items and announces each new one (HM-29).
    let inbox: InboxWatcher
    private(set) var paneProjects: [Project] = []
    private(set) var projectListFailure: ShellCopy?

    init(
        owner: any OwnerAPI, feed: EventFeed, health: HealthLineModel, navigator: Navigator = Navigator(),
        runtime: any AppRuntime
    ) {
        self.owner = owner
        self.feed = feed
        self.health = health
        self.navigator = navigator
        self.runtime = runtime
        self.inbox = InboxWatcher(
            owner: owner, notifier: runtime.notifier, cursor: runtime.inboxCursor,
            select: { [navigator] in navigator.show(.needsYou) })
    }

    /// Asks for permission to notify, then watches the inbox until the task
    /// is cancelled. The shell runs it while the owner is signed in.
    func startInbox() async {
        inbox.attach(to: feed)
        defer { inbox.detach() }
        await inbox.run()
    }

    /// Reads the pane's project names while the signed-in window is open.
    func watchProjects() async {
        let (updates, request) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = feed.subscribe { events in
            if events.contains(where: {
                $0.type == .projectCreated || ($0.type == .contentDeleted && $0.taskID == nil)
            }) {
                request.yield()
            }
        }
        defer {
            subscription.cancel()
            request.finish()
        }

        // The project list has no log position. If no screen has started
        // the feed, seed it with a position read before the project list.
        if feed.connection == .idle, let position = try? await owner.seats().asOfSeq, !Task.isCancelled {
            feed.noteRead(asOfSeq: position)
        }
        request.yield()
        for await _ in updates {
            do {
                let list = try await owner.listProjects()
                try Task.checkCancellation()
                paneProjects = list.projects
                projectListFailure = nil
            } catch {
                if Task.isCancelled { return }
                projectListFailure = ShellCopy.sentence(for: error)
            }
        }
    }
}


// SessionGuard forwards the Questions and approvals calls made by signed-in screens.
extension SessionGuard {
    func listDecisions() async throws -> DecisionsList {
        try await guardedOwnerCall { try await base.listDecisions() }
    }

    func listProjects() async throws -> ProjectsList {
        try await guardedOwnerCall { try await base.listProjects() }
    }

    func createProject(_ request: CreateProjectRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.createProject(request, key: key) }
    }

    func editBrief(projectID: UUID, _ request: EditBriefRequest, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.editBrief(projectID: projectID, request, key: key) }
    }

    func pauseProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.pauseProject(projectID: projectID, key: key) }
    }

    func resumeProject(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.resumeProject(projectID: projectID, key: key) }
    }

    func deleteProjectContent(projectID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.deleteProjectContent(projectID: projectID, key: key) }
    }

    func changeBudget(projectID: UUID, _ request: ChangeBudgetRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guardedOwnerCall { try await base.changeBudget(projectID: projectID, request, key: key) }
    }

    func changeTaskPriority(taskID: UUID, _ request: ChangeTaskPriorityRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guardedOwnerCall { try await base.changeTaskPriority(taskID: taskID, request, key: key) }
    }

    func changeTaskProject(taskID: UUID, _ request: ChangeTaskProjectRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guardedOwnerCall { try await base.changeTaskProject(taskID: taskID, request, key: key) }
    }

    func changeTaskCap(taskID: UUID, _ request: ChangeTaskCapRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guardedOwnerCall { try await base.changeTaskCap(taskID: taskID, request, key: key) }
    }

    func returnForRework(taskID: UUID, _ request: ReturnForReworkRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guardedOwnerCall { try await base.returnForRework(taskID: taskID, request, key: key) }
    }

    func offerTaskAgain(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.offerTaskAgain(taskID: taskID, key: key) }
    }

    func grantAccess(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.grantAccess(taskID: taskID, key: key) }
    }

    func deleteTaskContent(taskID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.deleteTaskContent(taskID: taskID, key: key) }
    }

    func answerQuestion(questionID: UUID, _ request: AnswerQuestionRequest, key: IdempotencyKey) async throws
        -> PlainOutcome {
        try await guardedOwnerCall { try await base.answerQuestion(questionID: questionID, request, key: key) }
    }

    func overturnAnswer(questionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.overturnAnswer(questionID: questionID, key: key) }
    }

    func approveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.approveAction(actionID: actionID, key: key) }
    }

    func stopAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.stopAction(actionID: actionID, key: key) }
    }

    func waiveAction(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.waiveAction(actionID: actionID, key: key) }
    }

    func markActionDone(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.markActionDone(actionID: actionID, key: key) }
    }

    func overturnApproval(actionID: UUID, key: IdempotencyKey) async throws -> PlainOutcome {
        try await guardedOwnerCall { try await base.overturnApproval(actionID: actionID, key: key) }
    }

    func changeWorkspaceSettings(_ request: ChangeWorkspaceSettingsRequest, key: IdempotencyKey) async throws
        -> CommandOutcome<WorkspaceSettings> {
        try await guardedOwnerCall { try await base.changeWorkspaceSettings(request, key: key) }
    }

    func workspaceSettings() async throws -> WorkspaceSettings {
        try await guardedOwnerCall { try await base.workspaceSettings() }
    }

    func landingPrompt(seatID: UUID, connection: LandingPromptConnection) async throws -> LandingPrompt {
        try await guardedOwnerCall { try await base.landingPrompt(seatID: seatID, connection: connection) }
    }

    private func guardedOwnerCall<Result: Sendable>(_ call: () async throws -> Result) async throws -> Result {
        do {
            return try await call()
        } catch let error as TransportError where error.code == .unauthenticated {
            await onUnauthenticated()
            throw error
        }
    }
}
