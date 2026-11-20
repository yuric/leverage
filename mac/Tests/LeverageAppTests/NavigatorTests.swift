import Foundation
import Testing

@testable import LeverageApp

/// The navigator carries Needs you's Change the task to the task page, which
/// then opens the editor (HM-24, HM-49).
@MainActor
@Suite("Navigator")
struct NavigatorTests {
    private let task = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private let other = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    @Test("opening a task to change it asks its page for the editor once")
    func editRequestedOnce() {
        let navigator = Navigator()
        navigator.open(task: task, editing: true)
        #expect(navigator.place == .board)
        #expect(navigator.openTaskID == task)
        #expect(!navigator.takeEditRequest(for: other))
        #expect(navigator.takeEditRequest(for: task))
        #expect(!navigator.takeEditRequest(for: task))
    }

    @Test("opening a task from a card asks for no editor")
    func plainOpen() {
        let navigator = Navigator()
        navigator.open(task: task)
        #expect(!navigator.takeEditRequest(for: task))
        navigator.open(task: task, editing: true)
        navigator.open(task: task)
        #expect(!navigator.takeEditRequest(for: task), "a later plain open drops the request")
    }

    @Test("leaving the task drops a request its page did not take")
    func leavingDrops() {
        let navigator = Navigator()
        navigator.open(task: task, editing: true)
        navigator.show(.needsYou)
        #expect(!navigator.takeEditRequest(for: task))
        navigator.open(task: task, editing: true)
        navigator.closeTask()
        #expect(!navigator.takeEditRequest(for: task))
    }
}
