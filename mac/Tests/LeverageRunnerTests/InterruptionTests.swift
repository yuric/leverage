import Foundation
import Testing

@testable import LeverageKit
@testable import LeverageRunner

/// The first version of `Interruption` (plan §2.2, HD-5): where no rule is
/// built yet it answers that the run goes on as milestone 2 does. WP11 adds
/// the detector, the rate-limit retry and the sign-in question.
@Suite("Interruption")
struct InterruptionTests {
    @Test("a failed run goes on as before until the rules are built")
    func goesOnAsBefore() async {
        let interruption = Interruption(provider: .claude, hasCredential: true)
        let record = ToolRunRecord(
            termination: .exited(1), standardOutput: Data(), standardError: Data("error".utf8))
        #expect(await interruption.decide(after: record, at: Date()) == .goOnAsBefore)
    }

    @Test("what it decides is one of two things the flows can act on")
    func decisions() {
        #expect(Interruption.Decision.goOnAsBefore != .accountStopped(.signedOut))
        #expect(Interruption.Decision.accountStopped(.signedOut) == .accountStopped(.signedOut))
    }
}
