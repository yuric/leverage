import SwiftUI

struct ActivityView: View {
    @Environment(ScreenContext.self) private var context
    @State private var box = ScreenModelBox<ActivityModel>()

    var body: some View {
        let model = box.model { ActivityModel(api: context.owner) }
        ActivityContent(model: model)
            .task {
                model.attach(to: context.feed)
                await model.load()
            }
            .onDisappear { model.detach() }
    }
}

struct ActivityContent: View {
    @Bindable var model: ActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(ActivityCopy.filter.text, selection: $model.filter) {
                Text(ActivityCopy.important.text).tag(ActivityModel.Filter.important)
                Text(ActivityCopy.everything.text).tag(ActivityModel.Filter.everything)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            if let failure = model.failure {
                Text(failure.text)
                    .font(.system(size: Tokens.FontSize.body))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
                if !model.isLoaded {
                    Button(ShellCopy.tryAgain.text) { Task { await model.load() } }
                }
            }

            if !model.isLoaded, model.failure == nil {
                ProgressView(ActivityCopy.loading.text)
            }

            if model.isLoaded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let entries = model.entries
                        if entries.isEmpty {
                            Text(ActivityCopy.empty.text)
                                .font(.system(size: Tokens.FontSize.body))
                                .foregroundStyle(Tokens.Palette.text2)
                        }
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: Tokens.FontSize.small))
                                    .foregroundStyle(Tokens.Palette.text2)
                                    .frame(width: 170, alignment: .leading)
                                Text(verbatim: entry.text)
                                    .font(.system(size: Tokens.FontSize.body))
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if model.hasEarlier {
                            Button(ActivityCopy.showEarlier.text) { Task { await model.showEarlier() } }
                                .disabled(model.isLoadingEarlier)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
