import Foundation
import LeverageKit
import Testing

@Suite("Reader labels")
struct ReaderLabelsTests {
    @Test("every figure label in readers.json uses owner-facing wording")
    func noBannedTerms() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LeverageAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("api/contract/readers.json")
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let readers = try #require(document["readers"]?.arrayValue)
        for reader in readers {
            let provider = try #require(reader["provider"]?.stringValue)
            let figures = try #require(reader["figures"]?.arrayValue)
            for figure in figures {
                let label = try #require(figure["label"]?.stringValue)
                #expect(BannedTerms.found(in: label).isEmpty, "\(provider): \(label)")
            }
        }
    }
}
