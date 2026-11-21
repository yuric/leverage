import Foundation
import LeverageKit

@MainActor
final class BriefEditorModel {
    struct Entry: Identifiable {
        var id = UUID()
        var kind: BriefEntryKind
        var text: String
    }

    var entries: [Entry] = []

    init(brief: [BriefEntry]) {}
}
