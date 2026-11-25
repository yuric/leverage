import AppKit
import SwiftUI

/// The screens before the app is ready: the server starting, Docker Desktop
/// missing or starting, a copy not built on this Mac, and a server that does
/// not answer (PK-3).
struct StartupView: View {
    let model: AppModel

    /// Docker's own page for getting Docker Desktop.
    static let dockerDesktopPage = URL(string: "https://www.docker.com/products/docker-desktop/")!

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 56)
            Text(title.text)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(detail.text)
                .font(.system(size: Tokens.FontSize.body))
                .foregroundStyle(Tokens.Palette.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if isWorking {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 8) {
                if model.phase == .dockerMissing {
                    Button(ShellCopy.getDockerDesktop.text) {
                        NSWorkspace.shared.open(Self.dockerDesktopPage)
                    }
                }
                if let again = againButton {
                    Button(again.text) { Task { await model.checkAgain() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var isWorking: Bool {
        model.phase == .starting || model.phase == .dockerStarting
    }

    private var againButton: ShellCopy? {
        switch model.phase {
        case .starting, .dockerStarting, .servicesUnavailable: nil
        case .dockerMissing, .dockerNotStarting: .checkAgain
        default: .tryAgain
        }
    }

    private var title: ShellCopy {
        switch model.phase {
        case .dockerMissing: .dockerMissingTitle
        case .dockerStarting: .dockerStartingTitle
        case .dockerNotStarting: .dockerNotStartingTitle
        case .imageMissing: .imageMissingTitle
        case .serverFailed: .serverFailedTitle
        case .servicesUnavailable: .servicesUnavailableTitle
        case .databasePasswordsMissing: .databasePasswordsMissingTitle
        case .cannotReachServer: .cannotReachTitle
        default: .startingTitle
        }
    }

    private var detail: ShellCopy {
        switch model.phase {
        case .dockerMissing: .dockerMissingBody
        case .dockerStarting: .dockerStartingBody
        case .dockerNotStarting: .dockerNotStartingBody
        case .imageMissing: .imageMissingBody
        case .serverFailed: .serverFailedBody
        case .servicesUnavailable: .servicesUnavailableBody
        case .databasePasswordsMissing: .databasePasswordsMissingBody
        case .cannotReachServer: .cannotReachBody
        default: .startingBody
        }
    }
}
