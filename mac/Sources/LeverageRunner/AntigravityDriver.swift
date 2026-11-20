import Foundation

/// Gemini, through the Antigravity tool `agy` (PV-2). One sign-in for the
/// Mac: no account variable.
///
/// The check: `agy -p <prompt> --output-format json --print-timeout <n>s`
/// (probe). A review adds `--mode plan` and a build `--mode accept-edits`
/// (help); `--model` and `--effort` when set (help). The folder is the
/// process's own: `agy` has no folder flag.
///
/// WP11's step 0 ran the "ready" prompt in `--mode plan`: it answered with a
/// plan to approve, not the word. So plan mode does not answer a plain
/// prompt, and `RunnerConfiguration` refuses a Gemini reviewer until that
/// is settled (CL-8).
///
/// The answer is `response`; the run failed when the exit is not 0 or
/// `status` is not `SUCCESS`; tokens are `usage.input_tokens` plus
/// `usage.output_tokens` (probe).
struct AntigravityDriver: ProviderShape {
    var usesOutputFile: Bool { false }

    func arguments(_ input: ShapeInput) -> [String] {
        var arguments = ["-p", input.prompt, "--output-format", "json", "--print-timeout", "\(input.timeoutSeconds)s"]
        switch input.purpose {
        case .check: break
        case .review: arguments += ["--mode", "plan"]
        case .build: arguments += ["--mode", "accept-edits"]
        }
        return arguments + ProviderShapes.flags(model: ("--model", input.model), effort: ("--effort", input.effort))
    }

    func read(standardOutput: Data, outputFile: Data?) throws -> ToolAnswer {
        guard let result = ProviderShapes.object(standardOutput) else { throw ToolFailure.unreadableOutput }
        guard result["status"] as? String == "SUCCESS" else { throw ToolFailure.reportedError }
        guard let text = result["response"] as? String else { throw ToolFailure.unreadableOutput }
        let usage = result["usage"] as? [String: Any]
        return ToolAnswer(
            text: text,
            tokens: ProviderShapes.count(usage?["input_tokens"]) + ProviderShapes.count(usage?["output_tokens"]))
    }
}
