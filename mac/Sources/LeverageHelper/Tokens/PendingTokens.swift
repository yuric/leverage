import Foundation

actor PendingTokens {
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    func insert(_ token: String, credentialID: UUID) {}

    func take(credentialID: UUID) async -> String? {
        try? await sleep(now() + .seconds(5))
        return nil
    }

    func discard(credentialID: UUID) {}
}
