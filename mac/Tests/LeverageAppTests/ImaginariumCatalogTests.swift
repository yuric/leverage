import Foundation
import Testing

@testable import LeverageApp

/// The prompt catalog the app ships (PRD FR-026 to FR-029), and the checks
/// that keep it sound (FR-028).
@Suite("ImaginariumCatalog")
struct ImaginariumCatalogTests {
    private typealias Catalog = ImaginariumCatalog

    private static let sound = Catalog.Entry(
        id: "pocket-to-do", category: "apps", title: "Pocket to-do", description: "A calm to-do app.",
        minutes: 40, fills: [.init(key: "look", label: "Look", defaultValue: "a paper notebook")],
        prompt: "Build a to-do app styled like {look}.", doneWhen: ["It opens", "Tasks are kept"], needs: [])

    private func catalog(_ entries: [Catalog.Entry]) -> Catalog {
        Catalog(version: 1, categories: [.init(id: "apps", name: "Apps")], entries: entries)
    }

    private func entry(
        id: String = sound.id, category: String = sound.category, title: String = sound.title,
        minutes: Int = sound.minutes, fills: [Catalog.Fill] = sound.fills, prompt: String = sound.prompt,
        doneWhen: [String] = sound.doneWhen
    ) -> Catalog.Entry {
        Catalog.Entry(
            id: id, category: category, title: title, description: Self.sound.description, minutes: minutes,
            fills: fills, prompt: prompt, doneWhen: doneWhen, needs: [])
    }

    // MARK: the launch catalog (FR-026, FR-029)

    @Test("the shipped catalog decodes and has no defect")
    func launchIsSound() throws {
        let launch = try Catalog.launch()
        #expect(launch.version >= 1)
        #expect(launch.problems() == [])
    }

    @Test("the shipped catalog has eight categories in order, with four entries each")
    func launchShape() throws {
        let launch = try Catalog.launch()
        #expect(launch.categories.map(\.name) == [
            "Pictures", "Websites", "Apps", "Games", "Automations", "Gifts", "Learning", "Home and life",
        ])
        #expect(launch.entries.count == 32)
        for category in launch.categories {
            #expect(launch.entries.filter { $0.category == category.id }.count == 4, "\(category.id)")
        }
    }

    @Test("every shipped picture prompt says it needs an image tool, and no entry needs anything else")
    func launchNeeds() throws {
        let launch = try Catalog.launch()
        for entry in launch.entries where entry.category == "pictures" {
            #expect(entry.needs == [.imageTool], "\(entry.id)")
        }
        #expect(launch.entries.allSatisfy { $0.needs.isEmpty || $0.needs == [.imageTool] })
    }

    // MARK: the checks (FR-028)

    @Test("a sound catalog has no defect")
    func soundCatalog() {
        #expect(catalog([Self.sound]).problems() == [])
    }

    @Test("each defect FR-028 names is found")
    func eachDefect() {
        let tooMany = (1...5).map { Catalog.Fill(key: "k\($0)", label: "L", defaultValue: "d") }
        let cases: [(String, [Catalog.Entry])] = [
            ("listed twice", [Self.sound, Self.sound]),
            ("does not exist", [entry(category: "games")]),
            ("has no fill-in", [entry(prompt: "Build {look} and {colour}.")]),
            ("is not used", [entry(prompt: "Build a to-do app.")]),
            ("brace that names no fill-in", [entry(prompt: "Build {look} with a { in it.")]),
            ("fill-in look is listed twice", [entry(fills: Self.sound.fills + Self.sound.fills)]),
            ("not 1 to 4", [entry(fills: tooMany, prompt: tooMany.map { "{\($0.key)}" }.joined())]),
            ("not 2 to 4", [entry(doneWhen: ["Only one"])]),
            ("Done when check is empty", [entry(doneWhen: ["It opens", " "])]),
            ("title is empty", [entry(title: "")]),
            ("not positive", [entry(minutes: 0)]),
            ("kebab-case", [entry(id: "Pocket_To_Do")]),
        ]
        for (expected, entries) in cases {
            let found = catalog(entries).problems()
            #expect(found.contains { $0.contains(expected) }, "\(expected): \(found)")
        }
    }

    @Test("an entry that needs something the app does not know does not decode")
    func unknownNeed() {
        let json = """
            {"version": 1, "categories": [{"id": "apps", "name": "Apps"}], "entries": [{"id": "x", "category": "apps",
            "title": "X", "description": "X.", "minutes": 5, "fills": [{"key": "a", "label": "A", "default": "a"}],
            "prompt": "{a}", "done_when": ["One", "Two"], "needs": ["a_spaceship"]}]}
            """
        #expect(throws: DecodingError.self) { try Catalog.decode(json) }
    }

    // MARK: filling in

    @Test("the filled prompt uses the owner's values, and the defaults for the rest")
    func filledPrompt() {
        let entry = entry(
            fills: [.init(key: "look", label: "Look", defaultValue: "paper"), .init(key: "extra", label: "E", defaultValue: "tags")],
            prompt: "Styled like {look}, with {extra}; {look} again.")
        #expect(entry.filledPrompt() == "Styled like paper, with tags; paper again.")
        #expect(entry.filledPrompt(["look": "a bullet journal"]) == "Styled like a bullet journal, with tags; a bullet journal again.")
    }
}
