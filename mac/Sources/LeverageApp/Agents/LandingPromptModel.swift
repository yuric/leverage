import Foundation
import LeverageKit
import Observation

/// Issues one landing prompt and keeps its text only while the sheet is open.
@MainActor
@Observable
final class LandingPromptModel {
    enum State: Equatable, Sendable, HidesToken {
        case none
        case loading
        case ready(String)
        case failed(String)

        var fieldsWithoutToken: [(String, String)] {
            let phase: String
            switch self {
            case .none: phase = "none"
            case .loading: phase = "loading"
            case .ready: phase = "ready"
            case .failed: phase = "failed"
            }
            return [("phase", phase)]
        }
    }

    private(set) var state: State = .none
    private(set) var copied = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let seatID: UUID
    @ObservationIgnored private let connection: LandingPromptConnection
    @ObservationIgnored private var pendingKey: IdempotencyKey?
    @ObservationIgnored private var closed = false

    init(api: any OwnerAPI, copy: @escaping @MainActor (String) -> Void, seatID: UUID, connection: LandingPromptConnection) {
        self.api = api
        self.copy = copy
        self.seatID = seatID
        self.connection = connection
    }

    func issue() async {
        guard !closed else { return }
        switch state {
        case .loading, .ready: return
        case .none, .failed: break
        }
        state = .loading
        do {
            // A repeat confirms the command ran, but its text is shown
            // only once. Try once more with a fresh key to get a new prompt.
            for _ in 0..<2 {
                let key = pendingKey ?? IdempotencyKey()
                pendingKey = key
                let outcome = try await api.issueLandingPrompt(seatID: seatID, connection: connection, key: key)
                guard !closed else { return }
                guard let answer = try outcome.completedResult() else { throw LeverageClientError.invalidBody }
                pendingKey = nil
                switch answer {
                case .shown(let prompt):
                    guard prompt.seatID == seatID, prompt.connection == connection,
                          TokenShape.containsOnly(prompt.seatToken, in: prompt.text) else {
                        throw LeverageClientError.invalidBody
                    }
                    state = .ready(prompt.text)
                    return
                case .repeated(let prompt):
                    guard prompt.seatID == seatID, prompt.connection == connection else {
                        throw LeverageClientError.invalidBody
                    }
                }
            }
            throw LeverageClientError.invalidBody
        } catch is CancellationError {
            if !closed { state = .failed(ShellCopy.somethingWentWrong.text) }
        } catch {
            guard !closed else { return }
            if CommandKey.wasAnswered(error) { pendingKey = nil }
            state = .failed(ShellCopy.sentence(for: error).text)
        }
    }

    func copyPrompt() {
        guard case .ready(let text) = state else { return }
        copy(text)
        copied = true
    }

    func close() {
        closed = true
        state = .none
        copied = false
        pendingKey = nil
    }
}
