import SwiftUI

struct AnswerSheet: View {
    @Bindable var model: NeedsYouModel
    let row: NeedsYouRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NeedsYouCopy.answerTitle.text).font(.headline)
            Text(verbatim: row.body)
                .foregroundStyle(Tokens.Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            TextField(NeedsYouCopy.answerTitle.text, text: $model.promptText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...8)
            NeedsYouSheetButtons(model: model, row: row, confirm: .sendAnswer)
        }
        .padding(20)
        .frame(width: 440)
    }
}
