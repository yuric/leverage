import Testing

@testable import LeverageKit

/// The two names the Rule checks milestone adds (plan section 2.4): both
/// read by `LeverageRunner eval` and `scripts/eval_rule.sh` and by nothing
/// else.
@Suite("EnvironmentKeys, the eval's names")
struct EnvironmentKeysEvalTests {
    @Test("the suite's name, and the switch for a run on real tools")
    func evalNames() {
        #expect(EnvironmentKeys.eval == "LEVERAGE_EVAL")
        #expect(EnvironmentKeys.evalReal == "LEVERAGE_EVAL_REAL")
    }
}
