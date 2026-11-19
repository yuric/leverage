import Foundation
import LeverageTestSupport
import Testing

/// The tests' patience setting, `LEVERAGE_TEST_PATIENCE`, which CI sets on
/// its slow macOS runner.
@Suite("Test patience")
struct PatienceTests {
    @Test("unset or empty, the tests wait as long as they were written to")
    func unset() throws {
        #expect(try Patience.factor(from: nil) == 1)
        #expect(try Patience.factor(from: "") == 1)
        #expect(try Patience.factor(from: "  ") == 1)
    }

    @Test("a number of at least 1 is the multiplier", arguments: [("1", 1.0), ("4", 4.0), ("2.5", 2.5), (" 3 ", 3.0)])
    func multiplier(text: String, factor: Double) throws {
        #expect(try Patience.factor(from: text) == factor)
    }

    @Test("anything else is refused, so a mistyped setting is not quietly ignored",
          arguments: ["0", "0.5", "-2", "four", "inf", "nan", "4x"])
    func refused(text: String) {
        #expect(throws: Patience.NotAFactor.self) { try Patience.factor(from: text) }
    }
}
