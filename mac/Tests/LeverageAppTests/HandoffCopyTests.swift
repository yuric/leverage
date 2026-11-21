import Foundation
import Testing

@testable import LeverageApp

/// The Handoff tab shows the PRD's eight sentences word for word (HM-32): the
/// test reads them from `docs/PRD.md` by path, so a change to the PRD that is
/// not made in the app too fails here.
@Suite("HandoffCopy")
struct HandoffCopyTests {
    private static let repository: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The numbered sentences that follow "The tab shows them in these words:".
    static func prdSentences() throws -> [String] {
        let prd = try String(contentsOf: repository.appending(path: "docs/PRD.md"), encoding: .utf8)
        let lines = prd.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasSuffix("The tab shows them in these words:") })
        var sentences: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if sentences.isEmpty { continue } else { break }
            }
            guard let dot = line.range(of: #"^\d+\. "#, options: .regularExpression) else { break }
            sentences.append(String(line[dot.upperBound...]))
        }
        return sentences
    }

    @Test("the PRD has eight sentences for the tab, and the file was found")
    func prdHasEight() throws {
        #expect(try Self.prdSentences().count == 8)
    }

    @Test("the eight sentences are the PRD's, word for word, in its order")
    func eightSentences() throws {
        let prd = try Self.prdSentences()
        #expect(HandoffCopy.rules.map(\.text) == prd)
    }

    @Test("the sentences are numbered from 1, and the order and rules are under the mockup's headings and hints")
    func headings() {
        #expect(HandoffCopy.rules.count == 8)
        #expect(HandoffCopy.title.text == "Handoff order")
        #expect(HandoffCopy.hint.text == "When one reaches its limit, the next one down takes over.")
        #expect(HandoffCopy.rulesTitle.text == "Rules")
        #expect(HandoffCopy.rulesHint.text == "Run by code, the same way every time.")
    }

    @Test("a row says who it hands off to, and the last one says nobody")
    func handsOff() {
        #expect(HandoffCopy.handsOffTo.filled(["account": "Codex, Team"]) == "Hands off to Codex, Team")
        #expect(HandoffCopy.handsOffToNobody.text == "Hands off to nobody")
    }

    @Test("move buttons and the drop hint have plain labels")
    func reorderWords() {
        #expect(HandoffCopy.moveUp.text == "Move up")
        #expect(HandoffCopy.moveDown.text == "Move down")
        #expect(HandoffCopy.dropHint.filled(["account": "Codex, Team", "number": "2"]) == "Drop to make Codex, Team number 2.")
        #expect(HandoffCopy.orderChanged.text == "The list changed. Try again.")
    }

    @Test("a row's state is one of the words HM-34 names")
    func stateWords() {
        #expect(HandoffCopy.stateReady.text == "Ready")
        #expect(HandoffCopy.stateWorking.text == "Working")
        #expect(HandoffCopy.stateSignedOut.text == "Signed out")
        #expect(HandoffCopy.stateLimit.text == "At its limit")
        #expect(HandoffCopy.stateLimitUntil.filled(["time": "6:00 PM"]) == "At its limit until 6:00 PM")
    }

    @Test("the mockup's fifth rule, on where a new login is placed, is not shown: it is not a rule of the PRD")
    func noPlacementRule() {
        for text in HandoffCopy.allTexts {
            #expect(!text.contains("placed above"), "\(text)")
            #expect(!text.contains("A new token goes"), "\(text)")
        }
    }

    @Test("the tab keeps the copy plain and out of account details")
    func noSwitchNoEmail() {
        for text in HandoffCopy.allTexts {
            #expect(!text.contains("@"), "\(text)")
            #expect(!text.contains("Nothing was lost"), "\(text)")
            #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
        }
    }

    @Test("every placeholder of a Handoff sentence is one the screen fills in")
    func placeholders() throws {
        let known: Set<String> = ["account", "time", "number"]
        let regex = try NSRegularExpression(pattern: #"\{(\w+)\}"#)
        for text in HandoffCopy.allTexts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                let name = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
                #expect(known.contains(name), "\(name) in \(text)")
            }
        }
    }
}
