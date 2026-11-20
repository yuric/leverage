import Foundation
import LeverageKit

/// A planner's or an orchestrator's work on jobs: claim the next job, hand it
/// to its kind's file (`CheckJob`, `DraftJob`), submit the result once; a
/// claim that returns the job the seat already holds continues it (RD-40);
/// while the tool runs, `GET /v1/next` with no wait every 30 seconds, its
/// answer ignored, so that the seat keeps counting as polling (RD-15).
/// A placeholder for WP14: it claims nothing and does nothing.
struct JobFlow: Sendable {
    let context: FlowContext

    /// Claims the next job and does it; nil when nothing was claimed.
    func claim() async throws -> FlowEnd? { nil }
}
