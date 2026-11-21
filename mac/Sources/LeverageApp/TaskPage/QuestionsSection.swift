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

    var body: some View { EmptyView() }
}
