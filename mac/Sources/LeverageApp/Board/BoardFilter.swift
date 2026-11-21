import Foundation

/// The project and agent shown on the Board. A nil field includes all.
struct BoardFilter: Equatable, Sendable {
    var projectID: UUID?
    var agentID: UUID?
}
