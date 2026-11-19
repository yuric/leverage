import Foundation
import LeverageKit
import Testing

@testable import LeverageRunner

// A placeholder until WP11: proves the runner lane builds and links its
// target, LeverageKit and LeverageTestSupport.
@Suite("LeverageRunner target")
struct RunnerTargetTests {
    @Test("the runner reads its seat token from the one name for it")
    func seatTokenName() {
        #expect(EnvironmentKeys.seatToken == "LEVERAGE_SEAT_TOKEN")
    }
}
