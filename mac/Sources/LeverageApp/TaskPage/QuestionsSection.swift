import Foundation
import SwiftUI

struct TaskQuestionRow: Identifiable {
    let id: UUID
    let question: String
    let askedBy: String
    let answer: String?
    let answerBy: String?
}

struct QuestionsSection: View {
    let rows: [TaskQuestionRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TaskPageCopy.sectionQuestions.text)
                .font(.system(size: Tokens.FontSize.small, weight: .semibold))
                .foregroundStyle(Tokens.Palette.text2)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: row.question)
                        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                        .textSelection(.enabled)
                    Text(TaskPageCopy.askedBy.filled(["name": row.askedBy]))
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                    if let answer = row.answer {
                        Text(verbatim: answer)
                            .font(.system(size: Tokens.FontSize.body))
                            .textSelection(.enabled)
                        if let name = row.answerBy {
                            Text(TaskPageCopy.answeredBy.filled(["name": name]))
                                .font(.system(size: Tokens.FontSize.small))
                                .foregroundStyle(Tokens.Palette.text2)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.inset, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            }
        }
    }
}
