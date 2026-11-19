import Foundation
import LeverageKit
import Testing

@testable import LeverageRunner

// Proves the runner lane builds and links its target, LeverageKit and
// LeverageTestSupport, and that the seat token has one name.
@Suite("LeverageRunner target")
struct RunnerTargetTests {
    @Test("the runner reads its seat token from the one name for it")
    func seatTokenName() {
        #expect(EnvironmentKeys.seatToken == "LEVERAGE_SEAT_TOKEN")
    }
}
