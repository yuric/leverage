import Foundation
import LeverageKit

enum DecisionParser {
    static func parse(_ text: String, nonce: String) -> ApprovalJobResult? {
        let frame = FramedOutput(text, nonce: nonce)
        let decisions = frame.fields(JobPrompts.decisionMarker(nonce))
        let reasons = frame.fields(JobPrompts.reasonMarker(nonce))
        guard decisions.count == 1, reasons.count <= 1,
              let decision = parseDecision(decisions[0].value)
        else { return nil }

        let reason = FramedOutput.limited(reasons.first?.value ?? "", to: ApprovalJobResult.reasonLimit)
        return ApprovalJobResult(decision: decision, reason: reason.isEmpty ? VerdictParser.noReason : reason)
    }

    private static func parseDecision(_ word: String) -> ApprovalDecision? {
        switch word.uppercased() {
        case "APPROVE": .approve
        case "STOP": .stop
        case "ASK_OWNER": .passToOwner
        default: nil
        }
    }
}

/// Keeps the output outside protocol quotes and matches markers on whole
/// lines. The original lines remain available for a multiline answer.
struct FramedOutput {
    let lines: [String]
    private let markers: [String]

    init(_ text: String, nonce: String) {
        let opening = JobPrompts.quoteOpening(nonce) + " "
        let closing = JobPrompts.quoteClosing(nonce)
        var lines: [String] = []
        var markers: [String] = []
        var quoteDepth = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let marker = line.trimmingCharacters(in: AnswerLines.wrapping)
            if marker.hasPrefix(opening), marker.hasSuffix(">>>") {
                quoteDepth += 1
            } else if marker == closing, quoteDepth > 0 {
                // A mention of a closing marker in quoted material does not close it.
                quoteDepth -= 1
            } else if quoteDepth == 0 {
                lines.append(line)
                markers.append(marker)
            }
        }
        self.lines = lines
        self.markers = markers
    }

    func positions(_ marker: String) -> [Int] {
        markers.indices.filter { markers[$0] == marker }
    }

    func fields(_ marker: String) -> [(line: Int, value: String)] {
        let prefix = marker + ":"
        return markers.enumerated().compactMap { index, line in
            AnswerLines.value(of: line, after: prefix).map { (index, $0) }
        }
    }

    /// The JSON schema counts Unicode scalars, including each part of a
    /// combined character. Keep line breaks and indentation inside the text.
    static func limited(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: trimmed.unicodeScalars.prefix(limit))
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
