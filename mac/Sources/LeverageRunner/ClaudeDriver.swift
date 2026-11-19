import Foundation

/// Claude Code (PV-2), the reference the other drivers follow (CL-2).
///
/// `claude -p <prompt> --output-format json --no-session-persistence
/// --permission-mode <mode> --strict-mcp-config --setting-sources user`.
/// The check adds `--tools ""` (probe); a review runs `dontAsk` and a build
/// `acceptEdits` (help), each with `--model` and `--effort` when set (help).
/// `--strict-mcp-config` takes no value and `--setting-sources user` is a
/// value its help lists (WP11's step 0): with `CLAUDE_CONFIG_DIR` on the
/// account folder leverage made, the work folder's own settings, hooks and
/// MCP servers are not loaded (CL-8). Never `--bare` (it ignores the login)
/// and never a mode or flag that skips permissions.
///
/// The answer is `result`; the run failed when the exit is not 0 or
/// `is_error` is true; tokens are `usage.input_tokens` plus
/// `usage.output_tokens` (probe).
struct ClaudeDriver: ProviderShape {
    var usesOutputFile: Bool { false }

    func arguments(_ input: ShapeInput) -> [String] {
        let mode = input.purpose == .build ? "acceptEdits" : "dontAsk"
        var arguments = [
            "-p", input.prompt, "--output-format", "json", "--no-session-persistence", "--permission-mode", mode,
            "--strict-mcp-config", "--setting-sources", "user",
        ]
        if input.purpose == .check { arguments += ["--tools", ""] }
        return arguments + ProviderShapes.flags(model: ("--model", input.model), effort: ("--effort", input.effort))
    }

    func read(standardOutput: Data, outputFile: Data?) throws -> ToolAnswer {
        guard let result = ProviderShapes.object(standardOutput) else { throw ToolFailure.unreadableOutput }
        if ProviderShapes.flag(result["is_error"]) != false { throw ToolFailure.reportedError }
        guard let text = result["result"] as? String else { throw ToolFailure.unreadableOutput }
        let usage = result["usage"] as? [String: Any]
        return ToolAnswer(
            text: text,
            tokens: ProviderShapes.count(usage?["input_tokens"]) + ProviderShapes.count(usage?["output_tokens"]))
    }
}
