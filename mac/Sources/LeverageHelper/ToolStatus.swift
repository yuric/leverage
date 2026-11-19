import Foundation
import LeverageKit

/// Is this account signed in (PV-3). Only the one fact is read: the status
/// output is never stored, logged or sent (IN-25).
struct ToolStatus: Sendable {
    let locator: ToolLocator
    let prober: any TestPrompting
    let settings: HelperSettings

    func isSignedIn(_ entry: ProviderEntry, tool: LocatedTool, accountFolder: URL?) async -> Bool {
        let check = entry.status.value
        if case .testPrompt = check.reading {
            return await prober.answers(entry, tool: tool, accountFolder: accountFolder, settings: settings)
        }
        guard let arguments = check.arguments,
              let result = try? await Subprocess.run(SubprocessRequest(
                  executable: tool.path, arguments: arguments,
                  environment: locator.toolEnvironment(entry, toolPath: tool.path, accountFolder: accountFolder),
                  timeLimit: locator.timings.commandLimit, gracePeriod: .seconds(2))),
              result.endedBy == nil
        else { return false }
        return Self.reads(check.reading, result)
    }

    /// What a status command's result says, by the catalog's reading.
    static func reads(_ reading: StatusCheck.Reading, _ result: SubprocessResult) -> Bool {
        switch reading {
        case .jsonField(let field):
            let object = try? JSONDecoder().decode(JSONValue.self, from: result.standardOutput)
            return object?[field] == .bool(true)
        case .exitCode:
            return result.termination == .exited(0)
        case .signedOutText(let text):
            let output = String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
            return result.termination == .exited(0) && !output.contains(text)
        case .testPrompt:
            return false
        }
    }
}
