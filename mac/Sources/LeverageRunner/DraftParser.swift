import Foundation
import LeverageKit

/// Reads a planner's contract from what its tool printed (milestone 4 plan
/// section 2.2, RD-37). Only the lines between the run's two markers are
/// read, never inside a block the tool echoed back, and nothing it printed
/// is ever logged.
enum DraftParser {
    /// The independent review the Add task form adds (`AddTaskCopy`), used
    /// when the task has no review criterion of its own.
    static let reviewCriterion = "An independent reviewer agrees."

    /// The contract in `text`, or nil for no draft: the JSON object between
    /// the nonce's two markers, with the task's title kept, each sentence a
    /// `build` criterion, the one `review` criterion the Add task form adds,
    /// no actions, and `work_reference`, `minimum_strength_rank` and
    /// `budget_cap` sent back exactly as `material` gave them (RD-37).
    static func parse(_ text: String, nonce: String, material: DraftMaterial) -> CompleteContractRequest? {
        guard let json = between(text, nonce: nonce),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let sentences = object["criteria"] as? [Any], !sentences.isEmpty
        else { return nil }
        var criteria: [CriterionInput] = []
        for sentence in sentences {
            guard let text = (sentence as? String).map(trimmed), !text.isEmpty else { return nil }
            criteria.append(CriterionInput(text: text, kind: .build))
        }
        let details: String?
        switch object["details"] {
        case nil, is NSNull: details = nil
        case let value as String: details = trimmed(value).isEmpty ? nil : trimmed(value)
        default: return nil
        }
        // The task's own review criterion keeps its words; else the form's.
        let review = material.criteria.first { $0.kind == .review }?.text ?? reviewCriterion
        criteria.append(CriterionInput(text: review, kind: .review))
        return CompleteContractRequest(
            title: material.title, details: details, criteria: criteria, actions: [],
            minimumStrengthRank: material.minimumStrengthRank, budgetCap: material.budgetCap,
            workReference: material.workReference)
    }

    /// The text between the one begin line and the one end line after it,
    /// outside any echoed block, with a code fence around it taken away;
    /// nil unless there is exactly one of each.
    private static func between(_ text: String, nonce: String) -> String? {
        let lines = AnswerLines.outsideEchoedBlocks(text, nonce: nonce, trim: false)
        let marks = lines.map { $0.trimmingCharacters(in: AnswerLines.wrapping) }
        let begins = marks.indices.filter { marks[$0] == JobPrompts.draftBegin(nonce) }
        let ends = marks.indices.filter { marks[$0] == JobPrompts.draftEnd(nonce) }
        guard begins.count == 1, ends.count == 1, let begin = begins.first, let end = ends.first, begin < end
        else { return nil }
        var inside = lines[(begin + 1)..<end].map(trimmed).filter { !$0.isEmpty }
        if inside.count >= 2, inside[0].hasPrefix("```"), inside[inside.count - 1] == "```" {
            inside = Array(inside.dropFirst().dropLast())
        }
        let joined = inside.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
