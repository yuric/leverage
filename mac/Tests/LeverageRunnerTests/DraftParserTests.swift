import Foundation
import LeverageKit
import Testing

@testable import LeverageRunner

// A planner's answer to the contract it sends (milestone 4 plan section
// 2.2, RD-37): one JSON object between the run's two markers; the task's
// title kept, each sentence a build criterion, the review criterion added,
// no actions, and the three stored values sent back unchanged.
@Suite("Draft parser")
struct DraftParserTests {
    static let nonce = "00aa11bb22cc"
    static let begin = "LEVERAGE-DRAFT-\(nonce)-BEGIN"
    static let end = "LEVERAGE-DRAFT-\(nonce)-END"

    func parse(_ text: String, material: DraftMaterial = JobFixture.draftMaterial()) -> CompleteContractRequest? {
        DraftParser.parse(text, nonce: Self.nonce, material: material)
    }

    func answer(_ json: String) -> String { "Here it is.\n\(Self.begin)\n\(json)\n\(Self.end)\nDone." }

    static let good = """
        {"details": "Figures from the llama sheet.", \
        "criteria": ["The walrus discount is named.", "Every price matches the sheet."]}
        """

    @Test("a draft keeps the title, makes each sentence a build criterion, adds the review and no actions")
    func good() throws {
        let contract = try #require(parse(answer(Self.good)))
        #expect(contract.title == JobFixture.title)
        #expect(contract.details == "Figures from the llama sheet.")
        #expect(contract.criteria == [
            CriterionInput(text: "The walrus discount is named.", kind: .build),
            CriterionInput(text: "Every price matches the sheet.", kind: .build),
            CriterionInput(text: DraftParser.reviewCriterion, kind: .review),
        ])
        #expect(contract.actions.isEmpty)
    }

    @Test("extra keys are ignored and stored values go back exactly as the material gave them")
    func storedValues() throws {
        let sneaky = """
            {"goal": 3, "details": null, "criteria": ["One."], "work_reference": "/tmp/elsewhere", \
            "minimum_strength_rank": 0, "budget_cap": 9999, "title": "Another title"}
            """
        let contract = try #require(parse(answer(sneaky), material: JobFixture.draftMaterial(details: nil)))
        #expect(contract.workReference == "/Users/example/sites/alpaca")
        #expect(contract.minimumStrengthRank == 2)
        #expect(contract.budgetCap == Decimal(string: "12.5"))
        #expect(contract.title == JobFixture.title)
        #expect(contract.details == nil)
        let empty = JobFixture.draftMaterial(workReference: nil, rank: nil, budget: nil, details: nil)
        let bare = try #require(parse(answer(sneaky), material: empty))
        #expect(bare.workReference == nil && bare.minimumStrengthRank == nil && bare.budgetCap == nil)
    }

    @Test("a draft cannot replace existing details with missing, null or blank text", arguments: [
        #"{"criteria": ["One."]}"#,
        #"{"details": null, "criteria": ["One."]}"#,
        #"{"details": "", "criteria": ["One."]}"#,
        #"{"details": " \t\r\n", "criteria": ["One."]}"#,
    ])
    func emptyReplacement(json: String) {
        let material = JobFixture.draftMaterial(details: "Folded goal.\n\nOwner details.")
        #expect(parse(answer(json), material: material) == nil)
    }

    @Test("a review criterion the task already has keeps its own words")
    func ownReview() throws {
        let material = JobFixture.draftMaterial(criteria: [
            CriterionInput(text: "A reviewer checks the narwhal copy.", kind: .review),
        ])
        let contract = try #require(parse(answer(Self.good), material: material))
        #expect(contract.criteria.filter { $0.kind == .review } == [
            CriterionInput(text: "A reviewer checks the narwhal copy.", kind: .review),
        ])
    }

    @Test("a draft with no JSON is no draft", arguments: [
        "I could not write a contract.",
        "LEVERAGE-DRAFT-00aa11bb22cc-BEGIN\nLEVERAGE-DRAFT-00aa11bb22cc-END",
        "LEVERAGE-DRAFT-00aa11bb22cc-BEGIN\n{\"criteria\": [\"One.\"]}",
    ])
    func noJSON(text: String) {
        #expect(parse(text) == nil)
    }

    @Test("a draft with bad JSON is no draft", arguments: [
        "{details: D}",
        "[\"One.\"]",
        "{\"details\": null, \"criteria\": \"One.\"}",
        "{\"details\": 3, \"criteria\": [\"One.\"]}",
        "{\"details\": null, \"criteria\": [\"One.\", 2]}",
    ])
    func badJSON(json: String) {
        #expect(parse(answer(json)) == nil)
    }

    @Test("a draft with no criteria or a blank criterion is no draft", arguments: [
        "{\"details\": null, \"criteria\": []}",
        "{\"details\": \"Work in the pricing page.\"}",
        "{\"details\": null, \"criteria\": [\"  \"]}",
    ])
    func noCriteria(json: String) {
        #expect(parse(answer(json)) == nil)
    }

    @Test("markers without the run's nonce, or inside an echoed block, are not the draft")
    func otherMarkers() {
        let other = "LEVERAGE-DRAFT-ffffffffffff-BEGIN\n\(Self.good)\nLEVERAGE-DRAFT-ffffffffffff-END"
        #expect(parse(other) == nil)
        let echoed = "<<<LEVERAGE-QUOTE-\(Self.nonce) details>>>\n\(answer(Self.good))\n<<<LEVERAGE-END-\(Self.nonce)>>>"
        #expect(parse(echoed) == nil)
        #expect(parse(answer(Self.good) + "\n" + answer(Self.good)) == nil, "two drafts are no draft")
    }

    @Test("a JSON object a model puts in a code fence between the markers is read")
    func fenced() {
        #expect(parse(answer("```json\n\(Self.good)\n```"))?.criteria.count == 3)
    }
}
