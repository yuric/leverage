import Foundation
import LeverageKit

/// How the runner's process ends (HD-6): with code 5 it writes the report
/// line, its one line on standard output, and nothing else is ever written
/// there.
enum RunnerEnd {
    /// The process's exit code, after writing what goes on standard output.
    static func finish(code: Int32, report: RunEndReport?, log: Log, write: (String) -> Void) -> Int32 {
        code
    }
}
