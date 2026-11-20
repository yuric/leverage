import Foundation
import LeverageKit

/// Is this account signed in (PV-3). The status command is LeverageKit's
/// `SignInStatus`, the one copy the runner uses too (plan §2.2, AR-002);
/// its output is never stored, logged or sent (IN-25). Where the provider
/// has no status command (Antigravity), the answering check, a test
/// prompt, is the sign-in check.
struct ToolStatus: Sendable {
    let locator: ToolLocator
    let prober: any TestPrompting
    let settings: HelperSettings

    func isSignedIn(_ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?) async -> Bool {
        let answer = await SignInStatus.check(
            entry, toolPath: tool.path,
            environment: locator.toolEnvironment(entry, toolPath: tool.path, accountFolder: accountFolder),
            timeLimit: locator.timings.commandLimit)
        switch answer {
        case .signedIn: return true
        case .signedOut, .couldNotTell: return false
        case .noStatusCommand:
            return await prober.answers(entry, tool: tool, accountFolder: accountFolder, settings: settings)
        }
    }
}
