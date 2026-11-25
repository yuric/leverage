import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// The setup checklist, its side-pane progress, the sent-task line and the
/// spotlight draw, in both appearances. Clicks through the shade need a
/// window and a person; they are not covered here.
@MainActor
@Suite("Setup checklist and spotlight render smoke")
struct SpotlightRenderTests {
    private typealias Points = SetupPoints

    private func png(_ view: some View, width: CGFloat, height: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
        renderer.scale = 1
        return renderer.nsImage?.tiffRepresentation
    }

    private func bothAppearances(_ view: some View, width: CGFloat = 900, height: CGFloat = 320) -> Bool {
        Fixtures.draws(view.background(Color.white), width: width, height: height)
            && Fixtures.draws(view.environment(\.colorScheme, .dark).background(Color.white), width: width, height: height)
    }

    private func card(_ facts: SetupModel.Facts, cards: [BoardCard] = []) -> some View {
        SetupChecklistCard(
            content: SetupChecklistContent(facts: facts, cards: cards), showMe: {}, hide: {}, finish: {})
    }

    @Test("the card draws at each point of setup, and the finished strip draws, light and dark")
    func cardStates() {
        for facts in [
            Points.fresh, Points.oneLogin, Points.twoLogins, Points.oneAgent, Points.agents, Points.running, Points.done,
        ] {
            #expect(bothAppearances(card(facts)), "\(facts.doneCount)")
        }
    }

    @Test("the sent-task line and the side pane's progress draw, light and dark")
    func lineAndPill() {
        #expect(bothAppearances(SentTaskLine(text: "You are set up.", close: {}), height: 60))
        #expect(bothAppearances(SetupProgressPill(doneCount: 2, open: {}), width: 172, height: 60))
    }

    @Test("the spotlight draws each kind of note, light and dark")
    func overlay() {
        let target = CGRect(x: 40, y: 200, width: 160, height: 32)
        for (facts, place) in [
            (Points.fresh, Navigator.Place.board), (Points.fresh, .credentials), (Points.agents, .board),
            (Points.done, .board),
        ] {
            guard let note = SetupGuide.note(for: facts, place: place, taskPageOpen: false) else {
                Issue.record("no note for \(place)")
                continue
            }
            let overlay = SpotlightOverlay(
                note: note, target: target, size: CGSize(width: 900, height: 620), notNow: {}, finish: {})
            #expect(bothAppearances(overlay, height: 620), "\(note.title)")
        }
    }

    @Test("the shade is drawn over the window except for the lit control's hole")
    func shadeHasAHole() {
        let hole = CGRect(x: 100, y: 100, width: 80, height: 40)
        let path = SpotlightShade(hole: hole).path(in: CGRect(x: 0, y: 0, width: 400, height: 300)).cgPath
        let filled = { (point: CGPoint) in path.contains(point, using: .evenOdd) }
        #expect(filled(CGPoint(x: 10, y: 10)))
        #expect(filled(CGPoint(x: 390, y: 290)))
        #expect(!filled(CGPoint(x: 140, y: 120)))
        #expect(filled(CGPoint(x: 140, y: 160)))
    }

    @Test("the shade takes clicks everywhere but the hole, by the rule SwiftUI tests clicks with")
    func shadeTakesClicksOutsideTheHole() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let hole = CGRect(x: 100, y: 100, width: 80, height: 40)
        let area = SpotlightShadeHitArea(hole: hole).path(in: bounds)
        for point in [
            CGPoint(x: 10, y: 10), CGPoint(x: 140, y: 50), CGPoint(x: 50, y: 120), CGPoint(x: 300, y: 120),
            CGPoint(x: 140, y: 200), CGPoint(x: 390, y: 290),
        ] {
            #expect(area.contains(point), "\(point)")
        }
        #expect(!area.contains(CGPoint(x: 140, y: 120)))
        #expect(!area.contains(CGPoint(x: 101, y: 101)))
        // A hole partly off the window still leaves the rest of it open.
        let edge = SpotlightShadeHitArea(hole: CGRect(x: -10, y: 50, width: 60, height: 30)).path(in: bounds)
        #expect(!edge.contains(CGPoint(x: 5, y: 60)))
        #expect(edge.contains(CGPoint(x: 5, y: 10)))
    }

    @Test("the task board draws the checklist above the lanes, and nothing extra after setup")
    func boardWithChecklist() async {
        let rig = ShellRig()
        rig.runtime.fakeSetupProgress.stored.value = .skipped
        rig.owner.script {
            $0.credentials = { CredentialsList(credentials: [Points.claude], asOfSeq: 2) }
            $0.seats = { SeatsList(seats: [], asOfSeq: 2) }
            $0.board = { Board(tasks: [], asOfSeq: 2, reviewerSeatExists: true) }
        }
        let context = ScreenContext(
            owner: rig.owner, feed: EventFeed(owner: rig.owner),
            health: HealthLineModel(owner: rig.owner, helper: rig.runtime.helper), runtime: rig.runtime)
        await context.setup.load()
        #expect(context.setup.presentation == .checklist)
        let withCard = png(BoardView().environment(context), width: 900, height: 620)
        #expect(Fixtures.draws(BoardView().environment(context)))
        #expect(Fixtures.draws(SidePane(context: context, settingsAreOpen: false, signOut: {})))

        context.setup.finishChecklist()
        let without = png(BoardView().environment(context), width: 900, height: 620)
        #expect(withCard != nil && without != nil)
        #expect(withCard != without)
    }

    @Test("Add credential draws its provider line only when it is given one")
    func addCredentialHint() {
        let model = AddCredentialModel(api: Fixtures.owner(), onAdded: {}, helper: FakeAppRuntime().helper)
        let plain = png(AddCredentialForm(model: model, cancel: {}), width: 440, height: 520)
        let hinted = png(
            AddCredentialForm(
                model: model, cancel: {},
                providerHint: "Pick a different provider from Claude, so one agent can review the other’s work."),
            width: 440, height: 520)
        #expect(plain != nil && hinted != nil)
        #expect(plain != hinted)
    }
}
