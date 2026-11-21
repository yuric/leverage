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

    func selectProject(_ id: UUID?) {}

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
/// The shell builds the five screens with no arguments (`BoardView()`,
/// `TaskPageView()`, `AddTaskSheet()`, `RosterView()`, `CredentialsView()`)
/// and gives each its context this way, so a screen's own files never need
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
}
