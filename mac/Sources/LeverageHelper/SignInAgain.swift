import Foundation
import LeverageKit

/// The `open_sign_in` request, Sign in again (plan §2.2, HE-36, HM-25): the
/// provider's own sign-in through `SignInWindow` with milestone 2's wait
/// (PV-4, CL-19), then the verify checks, and the request's result, which
/// the request loop reports. A pass is Verify's pass; a failed sign-in check
/// is the server's sign-out; any other failure changes nothing on the
/// server. Each check's state is reported while it runs, so the app can say
/// it is waiting for the owner's sign-in (MA-17).
///
/// For Gemini and Grok this is milestone 2's path and as unverified as it
/// is there (HM-25): Antigravity has no sign-in command, so the owner signs
/// in on this Mac and a repeated test prompt notices.
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
        await AddChecks(api: api, settings: settings, timings: timings, prober: prober, log: log)
            .signInAgain(request)
    }
}
