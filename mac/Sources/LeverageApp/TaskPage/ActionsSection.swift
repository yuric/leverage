import Foundation
import SwiftUI

struct TaskActionRow: Identifiable {
    let id: UUID
    let kind: String
    let description: String
    let state: String
    let approvedBy: String?
}

struct ActionsSection: View {
    let rows: [TaskActionRow]

    var body: some View { EmptyView() }
}
