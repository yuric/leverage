import Foundation

/// `LeverageRunner eval --inputs <file> --provider <name> --out <file>
/// [--account-folder <dir>]`: the eval suite's cases through `CheckJob`'s
/// prompt, tool run and parser (milestone 4 plan section 2.2, RV-6). A
/// placeholder for WP19: it says it is not built and exits 2, which is also
/// the code the real one gives for a refused start. Nothing dispatches to it
/// yet: WP14 adds the subcommand to `main.swift`.
enum EvalRun {
    static let exitCode: Int32 = 2

    static func run(arguments: [String], environment: [String: String]) async -> Int32 {
        FileHandle.standardError.write(Data("eval: not built\n".utf8))
        return exitCode
    }
}
