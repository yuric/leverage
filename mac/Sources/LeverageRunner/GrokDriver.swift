import Foundation

/// Grok Build, `grok` (PV-2). It has never run a prompt on this Mac (not
/// signed in), so every flag here is `help`. One sign-in for the Mac
/// (CL-21).
///
/// The check: `grok -p <prompt> --cwd <folder>`. A review adds
/// `--permission-mode plan` and a build `--permission-mode acceptEdits`;
/// `-m` when set. Never `--always-approve` or `bypassPermissions`.
///
/// The output is read as plain text on purpose: `--output-format json` is
/// listed but its shape has never been seen, and the marker lines need
/// only text. Tokens are 0. The run failed when the exit is not 0, or the
/// text is the signed-out answer `grok models` gives.
struct GrokDriver: ProviderShape {
    static let signedOutText = "You are not authenticated."

    var usesOutputFile: Bool { false }

    func arguments(_ input: ShapeInput) -> [String] {
        var arguments = ["-p", input.prompt, "--cwd", input.folder]
        switch input.purpose {
        case .check: break
        case .review: arguments += ["--permission-mode", "plan"]
        case .build: arguments += ["--permission-mode", "acceptEdits"]
        }
        return arguments + ProviderShapes.flags(model: ("-m", input.model), effort: nil)
    }

    func read(standardOutput: Data, outputFile: Data?) throws -> ToolAnswer {
        guard let text = String(data: standardOutput, encoding: .utf8) else { throw ToolFailure.unreadableOutput }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Self.signedOutText) {
            throw ToolFailure.reportedError
        }
        return ToolAnswer(text: text, tokens: 0)
    }
}
