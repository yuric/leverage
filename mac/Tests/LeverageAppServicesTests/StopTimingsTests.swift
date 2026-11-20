import Foundation
import LeverageKit
import Testing

@testable import LeverageAppServices

/// When the app quits, it gives the helper longer to stop than the helper
/// gives its runners plus what a runner spends giving back what its seat
/// holds, so the app never ends the helper's group while the helper still
/// waits on a runner (CL-23, PK-8).
@Suite("Stop timings")
struct StopTimingsTests {
    @Test("the app's grace for the helper is longer than the helper's for its runners plus a runner's give-back")
    func appWaitsLongerThanHelper() {
        let configuration = HelperSupervisor.Configuration(
            helperProgram: URL(fileURLWithPath: "/made-up/LeverageHelper"),
            supportFolder: URL(fileURLWithPath: "/made-up/support"), environment: [:])
        #expect(configuration.stopGracePeriod == StopTimings.helperStopGrace)
        #expect(StopTimings.helperStopGrace > StopTimings.runnerStopGrace + StopTimings.runnerGiveBack)
    }
}
