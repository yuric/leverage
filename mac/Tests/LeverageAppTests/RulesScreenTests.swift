import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing
import Vision

@testable import LeverageApp

/// The Rules screen and its sheet draw, in both appearances, in each state
/// they can be in. Clicks and focus need a person and are not covered here.
@MainActor
@Suite("Rules screen")
struct RulesScreenTests {
    private typealias Fixtures = AgentFixtures

    private func loadedModel() async throws -> RulesModel {
        var rows = try RulesFixtures.shippedRows()
        rows.append(RulesFixtures.row(
            number: 50, name: "Mention the date", enabled: false,
            stats: RulesFixtures.stats(checks: 4, average: 12, tokens: 900, spend: 0, overrides: 1)))
        return await loadedModel(rows: rows)
    }

    private func loadedModel(rows: [RuleRow]) async -> RulesModel {
        let owner = FakeOwnerAPI()
        owner.script { $0.listRules = { RulesList(rules: rows) } }
        let model = RulesModel(api: owner, calendar: RulesFixtures.utc, locale: RulesFixtures.usEnglish)
        await model.load()
        return model
    }

    private func visibleRuleList(_ model: RulesModel) throws -> [String] {
        // ImageRenderer omits the native scroll view. Draw it in an offscreen hosting view.
        _ = NSApplication.shared
        let content = RulesContent(model: model, change: { _ in }, add: {})
            .environment(\.colorScheme, .light)
            .background(.white)
        let view = NSHostingView(rootView: content)
        view.frame.size = NSSize(width: 1100, height: 1800)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        let listText = Set(model.lines.map(\.name) + ["Orchestrator rules", "Other agent rules"])
        let text = try #require(request.results)
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
        try #require(text.contains("Rules"), "Rendered text: \(text)")
        return text.filter { listText.contains($0) }
    }

    @Test("the screen groups the seven shipped rules and a custom rule by checker in their original order")
    func groupsRulesByChecker() async throws {
        let model = try await loadedModel()
        let visible = try visibleRuleList(model)
        #expect(visible == [
            "Orchestrator rules",
            "Every task needs specific details",
            "The orchestrator approves outward actions itself",
            "Mention the date",
            "Other agent rules",
            "Every task needs acceptance criteria",
            "Workers ask the orchestrator before they ask you",
            "A different provider reviews every task",
            "Repeated failed reviews move a task to a stronger model",
            "Projects pause when they reach their budget",
        ])
    }

    @Test("the screen hides empty rule sections", arguments: [RuleChecker.model, .app])
    func hidesEmptySections(_ checker: RuleChecker) async throws {
        let name = "Require a date"
        let model = await loadedModel(rows: [RulesFixtures.row(name: name, checker: checker)])
        let heading = checker == .model ? "Orchestrator rules" : "Other agent rules"
        let visible = try visibleRuleList(model)
        #expect(visible == [heading, name])
    }

    @Test("the screen draws with every rule, in both appearances")
    func drawsLoaded() async throws {
        let model = try await loadedModel()
        #expect(model.lines.count == 8)
        #expect(Fixtures.draws(RulesContent(model: model, change: { _ in }, add: {}), height: 900))
        #expect(Fixtures.draws(
            RulesContent(model: model, change: { _ in }, add: {}).environment(\.colorScheme, .dark), height: 900))
    }

    @Test("the screen draws while loading, empty, and when the call failed")
    func drawsOtherStates() async {
        let loading = RulesModel(api: FakeOwnerAPI())
        #expect(Fixtures.draws(RulesContent(model: loading, change: { _ in }, add: {})))
        let empty = FakeOwnerAPI()
        empty.script { $0.listRules = { RulesList(rules: []) } }
        let none = RulesModel(api: empty)
        await none.load()
        #expect(none.state == .loaded)
        #expect(Fixtures.draws(RulesContent(model: none, change: { _ in }, add: {})))
        let failing = FakeOwnerAPI()
        failing.script { $0.listRules = { throw URLError(.timedOut) } }
        let failed = RulesModel(api: failing)
        await failed.load()
        #expect(Fixtures.draws(RulesContent(model: failed, change: { _ in }, add: {})))
    }

    @Test("the sheet draws for Add, for a shipped model rule, a shipped app rule and a custom rule")
    func drawsSheet() throws {
        let shipped = try RulesFixtures.shippedRows()
        let modes: [RuleEditorModel.Mode] = [
            .add, .change(shipped[0]), .change(shipped[1]), .change(RulesFixtures.row(number: 50, origin: .custom)),
        ]
        for mode in modes {
            let model = RuleEditorModel(mode: mode, api: FakeOwnerAPI(), onDone: {})
            #expect(Fixtures.draws(RuleEditorSheet(model: model, cancel: {}), width: 480, height: 560), "\(mode)")
            #expect(Fixtures.draws(
                RuleEditorSheet(model: model, cancel: {}).environment(\.colorScheme, .dark), width: 480, height: 560))
        }
    }
}
