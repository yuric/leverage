import SwiftUI

struct ReworkSheet: View {
    @Bindable var model: NeedsYouModel
    let row: NeedsYouRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NeedsYouCopy.returnForRework.text).font(.headline)
            Text(NeedsYouCopy.criteriaToReopen.text)
                .foregroundStyle(Tokens.Palette.text2)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.reworkCriteria, id: \.id) { criterion in
                        Toggle(isOn: selection(for: criterion.id)) {
                            Text(verbatim: criterion.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            NeedsYouSheetButtons(model: model, row: row, confirm: .returnForRework)
        }
        .padding(20)
        .frame(width: 440)
    }

    private func selection(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.selectedCriterionIDs.contains(id) },
            set: { selected in
                if selected {
                    model.selectedCriterionIDs.insert(id)
                } else {
                    model.selectedCriterionIDs.remove(id)
                }
            })
    }
}
