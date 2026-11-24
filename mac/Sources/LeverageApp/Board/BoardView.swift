import Foundation
import LeverageKit
import SwiftUI

/// Keeps one view model for as long as the view lives, built the first time
/// the view's body needs it (the context is only in the environment then).
@MainActor
final class ScreenModelBox<Model> {
    private var model: Model?

    func model(make: () -> Model) -> Model {
        if let model { return model }
        let made = make()
        model = made
        return made
    }
}

/// The board: the screen of the Board tab (MA-1), with setup's checklist or
/// line above it while one applies. Built with no arguments; the shell puts
/// its `ScreenContext` in the environment.
struct BoardView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<BoardModel>()

    var body: some View {
        let model = box.model {
            BoardModel(api: context.owner, noteRead: { [feed = context.feed] in feed.noteRead(asOfSeq: $0) })
        }
        VStack(alignment: .leading, spacing: 12) {
            // Setup's line or checklist, only while one applies.
            if SetupBoardHeader.showsChecklist(context.setup) || context.setup.sentTaskTitle != nil {
                SetupBoardHeader(setup: context.setup, cards: model.cards)
            }
            BoardContent(
                model: model, navigator: context.navigator, projects: context.paneProjects,
                open: { context.navigator.open(task: $0) })
        }
        .task {
            model.attach(to: context.feed)
            await model.load()
        }
        .onDisappear { model.detach() }
    }
}

/// The board's filters, any read failure, and the lanes side by side.
struct BoardContent: View {
    @Bindable var model: BoardModel
    @Bindable var navigator: Navigator
    let projects: [Project]
    let open: (UUID) -> Void
    @Environment(ScreenContext.self) private var context: ScreenContext?

    /// The finished task's card, while the setup checklist shows.
    private var litCardID: UUID? {
        guard let setup = context?.setup, setup.presentation == .checklist else { return nil }
        return setup.facts.doneTask?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let line = notice {
                    Text(line.text)
                        .font(.system(size: Tokens.FontSize.body, weight: .medium))
                        .foregroundStyle(Tokens.Tone.stop.foreground)
                }
                projectPicker
                agentPicker
                Spacer(minLength: 0)
                Toggle(BoardCopy.showCancelled.text, isOn: $model.showCancelled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: Tokens.FontSize.small))
            }
            if model.state == .loading {
                Text(BoardCopy.loading.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    BoardLanes(lanes: model.lanes(matching: navigator.boardFilter), open: open)
                        .padding(.bottom, 8)
                }
                .spotlightAnchor(.boardLanes)
                .task(id: litCardID) {
                    // The spotlight lights the finished task's card: bring it into view.
                    guard let id = litCardID else { return }
                    reader.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var projectPicker: some View {
        Picker(BoardCopy.projectFilter.text, selection: $navigator.boardFilter.projectID) {
            Text(ShellCopy.allProjects.text).tag(nil as UUID?)
            ForEach(projects, id: \.id) { project in
                Text(verbatim: ProjectsCopy.projectName(project))
                    .tag(Optional(project.id))
            }
            if let selected = navigator.boardFilter.projectID, !projects.contains(where: { $0.id == selected }) {
                Text(BoardCopy.selectedProject.text).tag(Optional(selected))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 190)
    }

    private var agentPicker: some View {
        Picker(BoardCopy.agentFilter.text, selection: $navigator.boardFilter.agentID) {
            Text(BoardCopy.allAgents.text).tag(nil as UUID?)
            ForEach(model.builders, id: \.id) { builder in
                Text(verbatim: builder.name).tag(Optional(builder.id))
            }
            if let selected = navigator.boardFilter.agentID, !model.builders.contains(where: { $0.id == selected }) {
                Text(BoardCopy.selectedAgent.text).tag(Optional(selected))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 190)
    }

    private var notice: ShellCopy? {
        switch model.state {
        case .failed(let copy): copy
        case .signedOut: ShellCopy.transportUnauthenticated
        case .loading, .loaded: nil
        }
    }
}

/// The lanes side by side.
struct BoardLanes: View {
    let lanes: [LaneContent]
    let open: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(lanes) { lane in
                LaneView(content: lane, open: open)
            }
        }
    }
}

/// One lane: its heading and count, then its cards or a dashed empty box.
struct LaneView: View {
    let content: LaneContent
    let open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(content.lane.heading.text)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                Text(verbatim: String(content.count))
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Palette.text2)
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 8) {
                if content.cards.isEmpty {
                    Text(BoardCopy.emptyLane.text)
                        .font(.system(size: Tokens.FontSize.small))
                        .foregroundStyle(Tokens.Palette.text2)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                                .strokeBorder(Tokens.Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    ForEach(content.cards) { card in
                        TaskCard(card: card, open: open)
                            .id(card.id)
                    }
                }
            }
        }
        .frame(width: 208)
    }
}
