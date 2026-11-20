import Foundation
import LeverageKit

/// The `open_sign_in` request (plan §2.2, HE-36): the provider's own
/// sign-in through `SignInWindow`, then the verify checks, then the
/// request's result. WP12 writes the body; this first version fails the
/// request, so a request that reaches it ends and is not left picked up.
struct SignInAgain: Sendable {
    let api: any HelperAPI
    let settings: HelperSettings
    let timings: HelperTimings
    let prober: any TestPrompting
    let log: Log

    init(
        api: any HelperAPI, settings: HelperSettings, timings: HelperTimings, prober: any TestPrompting, log: Log
    ) {
        self.api = api
        self.settings = settings
        self.timings = timings
        self.prober = prober
        self.log = log
    }

    /// Does one `open_sign_in` request and says how it ended.
    func run(_ request: HelperRequest) async -> HelperRequestResult {
        HelperRequestResult(outcome: .failed, checks: [], toolVersion: nil)
    }
}
