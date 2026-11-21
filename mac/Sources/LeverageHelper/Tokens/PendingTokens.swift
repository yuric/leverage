import Foundation
import LeverageKit

/// A pasted token waits in the helper's memory for its Add request (CR-9).
actor PendingTokens: HidesToken {
    private static let arrivalLimit: Duration = .seconds(5)
    private static let lifetime: Duration = .seconds(60)

    private enum Payload: Sendable {
        case token(String)
        case waiter(CheckedContinuation<String?, Never>)
    }

    private struct Slot: Sendable {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let payload: Payload
        let timer: Task<Void, Never>

        func finish(returning token: String? = nil) {
            timer.cancel()
            if case .waiter(let continuation) = payload {
                continuation.resume(returning: token)
            }
        }
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var slots: [UUID: Slot] = [:]

    nonisolated var fieldsWithoutToken: [(String, String)] { [] }

    init(
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    deinit {
        for slot in slots.values { slot.finish() }
    }

    func insert(_ token: String, credentialID: UUID) {
        let receivedAt = now()
        if let slot = slots.removeValue(forKey: credentialID) {
            if case .waiter = slot.payload, receivedAt < slot.deadline {
                slot.finish(returning: token)
                return
            }
            slot.finish()
        }
        schedule(.token(token), credentialID: credentialID, id: UUID(), deadline: receivedAt + Self.lifetime)
    }

    func take(credentialID: UUID) async -> String? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            let token: String? = await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let startedAt = now()
                if let slot = slots[credentialID] {
                    // Only one Add can wait on this credential at a time.
                    guard case .token(let token) = slot.payload else {
                        continuation.resume(returning: nil)
                        return
                    }
                    discard(credentialID: credentialID)
                    if startedAt < slot.deadline {
                        continuation.resume(returning: token)
                        return
                    }
                }
                schedule(.waiter(continuation), credentialID: credentialID, id: waiterID,
                         deadline: startedAt + Self.arrivalLimit)
            }
            return Task.isCancelled ? nil : token
        } onCancel: {
            Task { await self.discard(credentialID: credentialID, ifCurrent: waiterID) }
        }
    }

    func discard(credentialID: UUID) {
        slots.removeValue(forKey: credentialID)?.finish()
    }

    private func schedule(_ payload: Payload, credentialID: UUID, id: UUID, deadline: ContinuousClock.Instant) {
        let timer = Task.detached { [weak self, sleep] in
            do {
                try await sleep(deadline)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.discard(credentialID: credentialID, ifCurrent: id)
        }
        slots[credentialID] = Slot(id: id, deadline: deadline, payload: payload, timer: timer)
    }

    private func discard(credentialID: UUID, ifCurrent id: UUID) {
        guard slots[credentialID]?.id == id else { return }
        discard(credentialID: credentialID)
    }
}
