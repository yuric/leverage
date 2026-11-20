import Foundation
import LeverageKit

/// How the runner's process ends (HD-6): with code 5 it writes the report
/// line, its one line on standard output, and nothing else is ever written
/// there. A code 5 with no line it can write is code 4, as the helper would
/// read it.
enum RunnerEnd {
    /// The process's exit code, after writing what goes on standard output.
    static func finish(code: Int32, report: RunEndReport?, log: Log, write: (String) -> Void) -> Int32 {
        guard code == RunnerExit.accountStopped.rawValue else { return code }
        guard let report, let line = try? report.line() else {
            log.error("the account stopped but its report could not be written")
            return RunnerExit.toolFailures.rawValue
        }
        write(line + "\n")
        return code
    }

    /// Writes to standard output at once, outside stdio's buffer.
    static func standardOutput(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
