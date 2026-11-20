import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = TaskScreenFixtures

/// The Timing section, the checklist, the sheet behind "Let it through once"
/// and the page that holds them, drawn with no window: each builds, lays out
/// and draws something. Clicks and focus need a person.
@MainActor
@Suite("Rule checks render")
struct RuleChecksRenderTests {
    private let taskID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    /// True when the picture is not one flat colour.
    private func draws(_ view: some View, width: CGFloat = 640, height: CGFloat = 700) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.white))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.bitmapData
        else { return false }
        let pixel = max(1, bitmap.bitsPerPixel / 8)
        for row in 0..<bitmap.pixelsHigh {
            let line = data + row * bitmap.bytesPerRow
            for column in 0..<bitmap.pixelsWide {
                let at = line + column * pixel
                for byte in 0..<pixel where at[byte] != data[byte] { return true }
            }
        }
        return false
    }

    private func loadedModel() async -> TaskPageModel {
        let checks = [
            Fixtures.check(result: .passed, reason: "It names the page and the user.", queue: 4, run: 8),
            Fixtures.check(hook: .taskBeforeSubmit, result: .failed, reason: "No test is named.", canOverride: true),
            Fixtures.check(result: .error, canOverride: true, canRerun: true),
            Fixtures.check(result: .notApplicable),
        ]
        let steps = [
            Fixtures.step(.idea, seconds: 600), Fixtures.step(.check, .ruleCheck, seconds: 45),
            Fixtures.step(.build, seconds: 120, open: true),
        ]
        let page = Fixtures.checkedPage(
            Fixtures.summary(.backlog, id: taskID), steps: steps, checks: checks, draft: .notWritten)
        let owner = FakeOwnerAPI()
        owner.script { $0.task = { _ in page } }
        let model = TaskPageModel(taskID: taskID, api: owner, noteRead: { _ in })
        await model.load()
        return model
    }

    @Test("the Timing section and the checklist draw, light and dark")
    func sectionsDraw() async throws {
        let model = await loadedModel()
        let timing = try #require(model.timing)
        #expect(draws(TimingSection(timing: timing)))
        #expect(draws(TimingSection(timing: timing).environment(\.colorScheme, .dark)))
        #expect(draws(RuleChecklist(model: model)))
        #expect(draws(RuleChecklist(model: model).environment(\.colorScheme, .dark)))
    }

    @Test("the page with its checks, its timing and Draft the details draws")
    func pageDraws() async {
        let model = await loadedModel()
        #expect(model.canDraftDetails)
        #expect(draws(TaskPageBody(model: model), height: 1100))
        #expect(draws(TaskPageBody(model: model).environment(\.colorScheme, .dark), height: 1100))
    }

    @Test("the sheet behind Let it through once draws, light and dark")
    func sheetDraws() async throws {
        let model = await loadedModel()
        let id = try #require(model.checks.first { $0.canLetThrough }?.id)
        model.askToLetThrough(id)
        let sheet = try #require(model.letThrough)
        #expect(draws(LetThroughSheet(model: sheet, cancel: {}), height: 320))
        #expect(draws(LetThroughSheet(model: sheet, cancel: {}).environment(\.colorScheme, .dark), height: 320))
    }
}
