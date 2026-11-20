import Testing

@testable import LeverageKit

/// The names the Handoff milestone adds (plan §2.4).
@Suite("EnvironmentKeys")
struct EnvironmentKeysTests {
    @Test("the runner's credential and the work to continue; the app's notifications switch")
    func handoffNames() {
        #expect(EnvironmentKeys.credentialID == "LEVERAGE_CREDENTIAL_ID")
        #expect(EnvironmentKeys.continueTaskID == "LEVERAGE_CONTINUE_TASK_ID")
        #expect(EnvironmentKeys.continueReviewID == "LEVERAGE_CONTINUE_REVIEW_ID")
        #expect(EnvironmentKeys.notifications == "LEVERAGE_NOTIFICATIONS")
    }
}
