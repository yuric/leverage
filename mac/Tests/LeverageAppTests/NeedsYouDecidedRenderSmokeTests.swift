import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

@MainActor
@Suite("Needs you and Decided for you render smoke")
struct NeedsYouDecidedRenderSmokeTests {
    @Test("the two screens draw on the signed-in shell")
    func screensDraw() async {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.runtime.fakeSessions.token.value = "stored-made-up-token"
        let app = rig.makeModel()
        await app.start()
        guard let context = app.screens else {
            Issue.record("The signed-in app did not build its screen context")
            return
        }
        #expect(drawsSomething(NeedsYouView().environment(context)))
        #expect(drawsSomething(DecidedView().environment(context)))
    }

    @Test("the notification settings button draws only when notifications are off", arguments: [true, false])
    func notificationSettingsButton(notificationsAreOff: Bool) async throws {
        let owner = NeedsYouFixtures.owner(open: Locked([]))
        let model = NeedsYouModel(api: owner, noteRead: { _ in }, openTask: { _ in })
        await model.load()
        try #require(model.state == .loaded && model.rows.isEmpty)
        let content = NeedsYouContent(model: model, notificationsAreOff: notificationsAreOff)
        let rendered = try #require(picture(content.buttonStyle(TestButtonStyle()), height: 150))
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        #expect(hasButtonMarker(bitmap) == notificationsAreOff)
    }

    private struct TestButtonStyle: ButtonStyle {
        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            configuration.label.padding(4).background(Color(red: 1, green: 0, blue: 1))
        }
    }

    private func hasButtonMarker(_ bitmap: NSBitmapImageRep) -> Bool {
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                   color.redComponent > 0.95, color.greenComponent < 0.05, color.blueComponent > 0.95 {
                    return true
                }
            }
        }
        return false
    }

    @Test("loaded question and decision rows and their confirmations draw")
    func loadedScreens() async throws {
        let taskID = NeedsYouFixtures.taskID
        let questionID = UUID()
        let question = Question(
            id: questionID, taskID: taskID, askingSeatID: TaskScreenFixtures.builderID,
            text: "Which label?", assumption: "Blue", blocking: true, outcome: .passedOn)
        let item = NeedsYouFixtures.item(
            .questionPassedOn, seq: 31, choices: [.answer], facts: ["question_id": .string(questionID.contractString)])
        let owner = NeedsYouFixtures.owner(open: Locked([item]))
        let page = TaskPage(
            task: TaskScreenFixtures.summary(.working, id: taskID), questions: [question],
            reviewerSeatExists: true, asOfSeq: 31)
        let decision = Decision(
            questionID: UUID(), decidedAt: .distantPast, undoable: true, kind: .question, taskID: taskID,
            taskTitle: "Correct the totals", seatID: UUID(), summary: "Which line?", outcome: "The blue line.")
        owner.script {
            $0.task = { _ in page }
            $0.listDecisions = { DecisionsList(decisions: [decision]) }
        }
        let needs = NeedsYouModel(api: owner, noteRead: { _ in }, openTask: { _ in })
        await needs.load()
        let row = try #require(needs.rows.first)
        // ImageRenderer omits the native scroll view. Render its populated row directly.
        #expect(drawsSomething(NeedsYouRowView(row: row, model: needs)))
        await needs.perform(.answerDifferently, on: item.id)
        try #require(needs.prompt != nil)
        #expect(drawsSomething(AnswerSheet(model: needs, row: row)))

        let decided = DecidedModel(api: owner)
        await decided.load()
        #expect(drawsSomething(DecidedRowView(decision: decision, model: decided)))
        decided.requestUndo(decision)
        try #require(decided.confirming != nil)
        #expect(drawsSomething(
            DecidedRowView(decision: decision, model: decided).environment(\.colorScheme, .dark)))
    }

    private func drawsSomething(_ view: some View) -> Bool {
        guard let rendered = picture(view) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        guard let data = bitmap.bitmapData else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let at = row * bitmap.bytesPerRow + column * pixel
                if (0..<pixel).contains(where: { data[at + $0] != data[$0] }) { return true }
            }
        }
        return false
    }

    private func picture(_ view: some View, height: CGFloat = 620) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: 900, height: height).background(Color.white))
        renderer.scale = 1
        return renderer.cgImage
    }
}
