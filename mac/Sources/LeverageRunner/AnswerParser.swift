import Foundation
import LeverageKit

/// What a builder's tool run answered (CL-6).
enum BuilderAnswer: Equatable, Sendable {
    case evidence(String)
    case cannot(String)
    /// No marker line, or one with nothing after it.
    case none
}

/// What a reviewer's tool run answered: the builder criteria that failed,
/// by number, and the notes.
struct ReviewAnswer: Equatable, Sendable {
    let failed: [Int]
    let notes: String?
}

/// Marker lines out of a tool's answer. Only lines are read, never the
/// tool's structured output, and a line counts only when it starts with
/// the marker (after spaces and the `*` or `` ` `` a model may wrap it in).
enum AnswerParser {
    /// The longest evidence or reason kept.
    static let maximumLength = 2000

    /// The last evidence or cannot line of the answer.
    static func builder(_ text: String) -> BuilderAnswer {
        for line in lines(text).reversed() {
            if let value = value(of: line, after: Prompts.evidenceMarker) {
                return value.isEmpty ? .none : .evidence(value)
            }
            if let value = value(of: line, after: Prompts.cannotMarker) {
                return value.isEmpty ? .none : .cannot(value)
            }
        }
        return .none
    }

    /// An `https` address with a host is a link; anything else is a note
    /// locating the proof inside the work reference.
    static func evidence(_ value: String) -> EvidenceInput {
        if let url = URL(string: value), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
           !value.contains(where: \.isWhitespace) {
            return EvidenceInput(kind: .link, value: value)
        }
        return EvidenceInput(kind: .note, value: value)
    }

    /// A verdict for every expected number, or nil: a missing number, or one
    /// answered both ways, makes the answer unreadable (a release, CL-22).
    /// Numbers the prompt did not name are ignored.
    static func reviewer(_ text: String, expecting numbers: [Int]) -> ReviewAnswer? {
        var verdicts: [Int: Bool] = [:]
        var notes: String?
        for line in lines(text) {
            if let value = value(of: line, after: Prompts.notesMarker) {
                if !value.isEmpty { notes = value }
                continue
            }
            guard let rest = value(of: line, after: Prompts.criterionMarker),
                  let match = rest.wholeMatch(of: /(\d+)\s*:\s*(?i:(PASS|FAIL))\b.*/),
                  let number = Int(match.output.1) else { continue }
            let passed = match.output.2.uppercased() == "PASS"
            if let earlier = verdicts[number], earlier != passed { return nil }
            verdicts[number] = passed
        }
        guard numbers.allSatisfy({ verdicts[$0] != nil }) else { return nil }
        return ReviewAnswer(failed: numbers.filter { verdicts[$0] == false }, notes: notes)
    }

    /// The probe's check: the answer is the one word "ready".
    static func isReady(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() == "ready"
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { line in
            line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*`>")))
        }
    }

    /// What follows `marker` at the start of `line`, trimmed of spaces and
    /// wrapping, cut to the longest kept; nil when the line does not start
    /// with it.
    private static func value(of line: String, after marker: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        let value = line.dropFirst(marker.count)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*`")))
        return String(value.prefix(maximumLength))
    }
}
