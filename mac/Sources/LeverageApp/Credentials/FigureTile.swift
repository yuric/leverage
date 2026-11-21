import LeverageKit
import SwiftUI

/// One figure the provider supplied. Its label carries the unit, if any.
struct FigureTile: View {
    struct Content: Equatable, Sendable {
        let label: String
        let value: String?
        let resetLine: String?

        init(_ figure: Figure, clock: ResetClock) {
            label = figure.label
            if figure.kind == .limit, let used = figure.percentUsed {
                let percent = (used / 100).formatted(.percent.locale(clock.locale))
                value = CredentialsCopy.percentUsed.filled(["percent": percent])
            } else if let number = figure.value?.numberValue {
                value = number.formatted(.number.locale(clock.locale))
            } else {
                value = figure.value?.stringValue
            }
            resetLine = figure.resetAt.map {
                CredentialsCopy.resetsAt.filled(["time": ResetTime.text(for: $0, clock: clock)])
            }
        }
    }

    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            detail(content.label)
            if let value = content.value {
                Text(verbatim: value)
                    .font(.system(size: Tokens.FontSize.body, weight: .semibold))
                    .monospacedDigit()
            }
            if let reset = content.resetLine { detail(reset) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.flatSurface, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private func detail(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: Tokens.FontSize.small))
            .foregroundStyle(Tokens.Palette.text2)
    }
}
