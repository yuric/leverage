import Foundation

/// How patient the tests are, for a machine slower than the one they were
/// written on (a CI runner with three cores, under the whole package's tests
/// at once).
///
/// `LEVERAGE_TEST_PATIENCE` is a multiplier, 1 when unset. It lengthens only
/// what can never make a test pass wrongly: the waits for something that must
/// happen (`eventually`), the ceilings handed to the code under test for a
/// stand-in or a fake to answer, and the suites' time limits. A limit whose
/// shortness is what a test asserts is never multiplied.
public enum Patience {
    public static let variable = "LEVERAGE_TEST_PATIENCE"

    /// The multiplier this run uses.
    public static let factor: Double = {
        do {
            return try factor(from: ProcessInfo.processInfo.environment[variable])
        } catch {
            fatalError("\(variable) must be a number of at least 1, such as 4: \(error)")
        }
    }()

    public struct NotAFactor: Error, CustomStringConvertible {
        public let text: String
        public var description: String { "\"\(text)\" is not a number of at least 1" }
    }

    /// The multiplier `text` gives: 1 when it is missing or empty; otherwise
    /// a number of at least 1, or an error, so a mistyped setting is not
    /// quietly ignored.
    public static func factor(from text: String?) throws -> Double {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return 1 }
        guard let value = Double(text), value.isFinite, value >= 1 else { throw NotAFactor(text: text) }
        return value
    }

    /// `duration`, as patient as this run is.
    public static func scaled(_ duration: Duration) -> Duration { duration * factor }

    /// `seconds`, as patient as this run is.
    public static func seconds(_ seconds: Double) -> Double { seconds * factor }

    /// Whole minutes for a suite's `.timeLimit`, rounded up.
    public static func minutes(_ minutes: Int) -> Int { Int((Double(minutes) * factor).rounded(.up)) }
}
