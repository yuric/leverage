import Foundation
import LeverageKit

/// Turns what a runner reported when its account stopped into the helper's
/// report to the server (plan §2.2, HD-10): `report_limit` for a limit,
/// `report_signed_out` for a sign-out, under one key that a retry repeats,
/// and what follows a refusal (the code is logged and `report_run_stopped`
/// is sent with the reason `limit` or `signed_out`). The helper never sees
/// the tool's output; it has only the `RunEndReport`. WP12 writes the body;
/// this first version sends nothing.
struct InterruptionReporter: Sendable {
    /// What became of one report.
    enum Result: Equatable, Sendable {
        /// The server accepted the limit or sign-out report.
        case reported
        /// The server refused it; the run's end was reported as stopped.
        case refusedThenStopped
        /// Nothing was sent.
        case notSent
    }

    let api: any HelperAPI
    let log: Log

    init(api: any HelperAPI, log: Log) {
        self.api = api
        self.log = log
    }

    /// Reports the end of the run of `seatID` on `credentialID`.
    func report(_ end: RunEndReport, seatID: UUID, credentialID: UUID) async -> Result {
        .notSent
    }
}
