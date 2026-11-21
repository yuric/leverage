import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class BriefEditorModel {
    struct Entry: Identifiable {
        var id = UUID()
        var kind: BriefEntryKind
        var text: String
    }

    var entries: [Entry]

    init(brief: [BriefEntry]) {
        entries = brief.map { Entry(id: $0.id, kind: $0.kind, text: $0.text) }
    }

    var request: EditBriefRequest? {
        guard entries.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return EditBriefRequest(entries: entries.map { BriefEntryInput(kind: $0.kind, text: $0.text) })
    }

    func addEntry() { entries.append(Entry(kind: .rule, text: "")) }

    func removeEntry(_ id: UUID) { entries.removeAll { $0.id == id } }

    func canMoveEntry(_ id: UUID, by offset: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return entries.indices.contains(index + offset)
    }

    func moveEntry(_ id: UUID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else {
            return
        }
        entries.swapAt(index, index + offset)
    }
}
