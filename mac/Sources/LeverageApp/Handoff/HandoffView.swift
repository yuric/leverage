import SwiftUI

/// The Handoff tab shows the editable order and the PRD's eight fixed rules.
/// The shell puts its `ScreenContext` in the environment.
struct HandoffView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<HandoffModel>()

    var body: some View {
        let model = box.model {
            HandoffModel(api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) })
        }
        HandoffContent(model: model)
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
    }
}

/// What the tab draws from its model.
struct HandoffContent: View {
    let model: HandoffModel
    @State private var draggedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(HandoffCopy.title.text, hint: model.dropPreview?.hint ?? HandoffCopy.hint.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    order
                    rules
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: the order

    private var order: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .loading:
                note(HandoffCopy.loading.text)
            case .signedOut:
                note(ShellCopy.transportUnauthenticated.text, tone: Tokens.Tone.stop.foreground)
            case .failed(let copy):
                note(copy.text, tone: Tokens.Tone.stop.foreground)
            case .loaded:
                EmptyView()
            }
            if model.state == .loaded, model.rows.isEmpty {
                note(HandoffCopy.empty.text)
            }
            if let failure = model.reorderFailure {
                note(failure, tone: Tokens.Tone.stop.foreground)
            }
            ForEach(model.rows) { row in
                HandoffRowView(
                    row: row, model: model,
                    startDrag: { draggedID = row.id }
                )
                .onDrop(
                    of: [HandoffDrop.rowType],
                    delegate: HandoffDrop(model: model, targetID: row.id, draggedID: $draggedID)
                )
            }
        }
    }

    // MARK: the rules

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(HandoffCopy.rulesTitle.text, hint: HandoffCopy.rulesHint.text)
            ForEach(Array(HandoffCopy.rules.enumerated()), id: \.offset) { index, rule in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(index + 1).")
                        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.text2)
                        .frame(width: 22, alignment: .trailing)
                    Text(verbatim: rule.text)
                        .font(.system(size: Tokens.FontSize.body))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heading(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: hint)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
        }
    }

    private func note(_ text: String, tone: Color = Tokens.Palette.text2) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.body, weight: .medium))
            .foregroundStyle(tone)
    }
}

/// One account of the order and its keyboard and pointer controls.
private struct HandoffRowView: View {
    let row: HandoffRow
    let model: HandoffModel
    let startDrag: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: "\(row.number)")
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.text2)
                    .frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: row.name)
                        .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    Text(verbatim: row.handsOff)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                }
                Spacer(minLength: 0)
                Chip(text: row.state, tone: row.tone)
            }
            .contentShape(Rectangle())
            .onDrag {
                guard model.canMoveUp(row.id) || model.canMoveDown(row.id) else { return NSItemProvider() }
                startDrag()
                return HandoffDrop.provider()
            }
            moveButton(.moveUp, icon: "chevron.up", enabled: model.canMoveUp(row.id)) {
                await model.moveUp(row.id)
            }
            moveButton(.moveDown, icon: "chevron.down", enabled: model.canMoveDown(row.id)) {
                await model.moveDown(row.id)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Palette.line, lineWidth: 1))
        .overlay {
            if let preview = model.dropPreview, preview.targetID == row.id {
                Rectangle()
                    .fill(Tokens.Palette.focus)
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: preview.above ? .top : .bottom)
                    .offset(y: preview.above ? -4 : 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: row.name))
    }

    private func moveButton(
        _ copy: HandoffCopy, icon: String, enabled: Bool, action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
        }
        .disabled(!enabled)
        .help(copy.text)
        .accessibilityLabel(Text(verbatim: copy.text))
    }
}

/// The drag marker is visible to this app only. No account details travel in it.
private struct HandoffDrop: DropDelegate {
    static let rowType = "com.leverage.handoff-row"
    let model: HandoffModel
    let targetID: UUID
    @Binding var draggedID: UUID?

    static func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: rowType, visibility: .ownProcess) { complete in
            complete(Data(), nil)
            return nil
        }
        return provider
    }

    func dropEntered(info: DropInfo) {
        if let draggedID { model.previewDrop(of: draggedID, over: targetID) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let draggedID { model.previewDrop(of: draggedID, over: targetID) }
        return DropProposal(operation: model.dropPreview?.targetID == targetID ? .move : .cancel)
    }

    func dropExited(info: DropInfo) {
        model.clearDropPreview(over: targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedID else { return false }
        draggedID = nil
        model.previewDrop(of: id, over: targetID)
        guard model.dropPreview?.targetID == targetID else { return false }
        model.clearDropPreview(over: targetID)
        Task { await model.drop(id, over: targetID) }
        return true
    }
}
