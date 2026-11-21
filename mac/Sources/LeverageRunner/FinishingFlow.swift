import Foundation

/// The builder's work after approval. WP14 supplies the action handling.
struct FinishingFlow: Sendable {
    let context: FlowContext

    func continueTask(_ taskID: UUID, acknowledgement: Acknowledgement = .always) async throws -> FlowEnd {
        .ended
    }
}
