import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

/// The Rules screen and its sheet draw, in both appearances, in each state
/// they can be in. Clicks and focus need a person and are not covered here.
@MainActor
@Suite("Rules screen")
struct RulesScreenTests {
    private typealias Fixtures = AgentFixtures

    private func loadedModel() async throws -> RulesModel {
        let owner = FakeOwnerAPI()
        var rows = try RulesFixtures.shippedRows()
        rows.append(RulesFixtures.row(
            number: 50, name: "Mention the date", enabled: false,
            stats: RulesFixtures.stats(checks: 4, average: 12, tokens: 900, spend: 0, overrides: 1)))
        let all = rows
        owner.script { $0.listRules = { RulesList(rules: all) } }
        let model = RulesModel(api: owner, calendar: RulesFixtures.utc, locale: RulesFixtures.usEnglish)
        await model.load()
        return model
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
