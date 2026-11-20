import SwiftUI

/// The Handoff tab. A placeholder until WP16 builds it (HM-32 to HM-37): the
/// order of the logins and the PRD's eight sentences.
struct HandoffView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HandoffCopy.title.text)
                .font(.title2.weight(.semibold))
            Text(HandoffCopy.hint.text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
