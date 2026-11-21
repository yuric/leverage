import SwiftUI

struct AmountSheet: View {
    @Bindable var model: NeedsYouModel
    let row: NeedsYouRow
    let title: NeedsYouCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.text).font(.headline)
            if !row.body.isEmpty {
                Text(verbatim: row.body).foregroundStyle(Tokens.Palette.text2)
            }
            TextField(NeedsYouCopy.amount.text, text: $model.promptText)
                .textFieldStyle(.roundedBorder)
            Text(NeedsYouCopy.amountHint.text).foregroundStyle(Tokens.Palette.text2)
            NeedsYouSheetButtons(model: model, row: row, confirm: .saveAmount)
        }
        .padding(20)
        .frame(width: 360)
    }
}
