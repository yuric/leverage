import SwiftUI

/// The Needs you tab. A placeholder until WP14 builds it over
/// `needs_you.json` (HM-21): it says nothing needs the owner.
struct NeedsYouView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NeedsYouCopy.title.text)
                .font(.title2.weight(.semibold))
            Text(NeedsYouCopy.empty.text)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
