import AppKit
import SwiftUI

/// The work reference field used by Add task and the contract editor.
struct WorkReferenceField: View {
    @Binding var reference: String
    let projectID: UUID?
    @State private var input = WorkReferenceInput(
        pasteboard: SystemWorkReferencePasteboard(), folderPicker: SystemWorkReferenceFolderPicker())

    var body: some View {
        FormField(label: AddTaskCopy.workLabel.text, hint: AddTaskCopy.workHint.text) {
            HStack {
                TextField(AddTaskCopy.workPlaceholder.text, text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(AddTaskCopy.workLabel.text)
                if WorkReferenceInput.showsButtons(projectID: projectID, reference: reference) {
                    Button(AddTaskCopy.pasteWorkLink.text) {
                        if let pasted = input.pasteLink() { reference = pasted }
                    }
                    .fixedSize()
                    Button(AddTaskCopy.chooseWorkFolder.text) {
                        if let folder = input.chooseFolder() { reference = folder }
                    }
                    .fixedSize()
                }
            }
            if let problem = input.pasteProblem {
                Text(problem.text)
                    .font(.system(size: Tokens.FontSize.small))
                    .foregroundStyle(Tokens.Tone.stop.foreground)
            }
        }
        .onChange(of: reference) { _, _ in input.referenceChanged() }
    }
}

private struct SystemWorkReferencePasteboard: WorkReferencePasteboard {
    func readString() -> String? { NSPasteboard.general.string(forType: .string) }
}

private struct SystemWorkReferenceFolderPicker: WorkReferenceFolderPicker {
    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = AddTaskCopy.chooseFolderPrompt.text
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
