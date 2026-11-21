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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TaskPageCopy.sectionActions.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: row.kind)
                            .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(verbatim: row.state)
                            .font(.system(size: Tokens.FontSize.small))
                            .foregroundStyle(Tokens.Palette.text2)
                    }
                    Text(verbatim: row.description)
                        .font(.system(size: Tokens.FontSize.body))
                        .textSelection(.enabled)
                    if let name = row.approvedBy {
                        Text(TaskPageCopy.approvedBy.filled(["name": name]))
                            .font(.system(size: Tokens.FontSize.small))
                            .foregroundStyle(Tokens.Palette.text2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            }
        }
    }
}
