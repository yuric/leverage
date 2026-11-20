import Foundation

/// Codex (PV-2).
///
/// `codex exec <prompt> --json --sandbox <mode> --skip-git-repo-check
/// --ephemeral -C <folder> -o <file>` (probe). A review and the check run
/// `read-only`, a build `workspace-write` (help); `-m` when set (help).
/// Effort is not passed: it is a configuration key, not a flag, and which
/// key is not verified.
///
/// The answer is the `-o` file; the run failed when the exit is not 0 or
/// a JSON line has `type: error`; tokens are `turn.completed`'s
/// `usage.input_tokens` plus `usage.output_tokens` (probe).
struct CodexDriver: ProviderShape {
    var usesOutputFile: Bool { true }

    func arguments(_ input: ShapeInput) -> [String] {
        let sandbox = input.purpose == .build ? "workspace-write" : "read-only"
        var arguments = [
            "exec", input.prompt, "--json", "--sandbox", sandbox, "--skip-git-repo-check", "--ephemeral",
            "-C", input.folder,
        ]
        if let file = input.outputFile { arguments += ["-o", file] }
        return arguments + ProviderShapes.flags(model: ("-m", input.model), effort: nil)
    }

    func read(standardOutput: Data, outputFile: Data?) throws -> ToolAnswer {
        var tokens = 0
        for line in standardOutput.split(separator: UInt8(ascii: "\n")) {
            guard let event = ProviderShapes.object(Data(line)) else { continue }
            switch event["type"] as? String {
            case "error": throw ToolFailure.reportedError
            case "turn.completed":
                let usage = event["usage"] as? [String: Any]
                tokens += ProviderShapes.count(usage?["input_tokens"]) + ProviderShapes.count(usage?["output_tokens"])
            default: continue
            }
        }
        guard let outputFile, let text = String(data: outputFile, encoding: .utf8) else {
            throw ToolFailure.unreadableOutput
        }
        return ToolAnswer(text: text, tokens: tokens)
    }
}
