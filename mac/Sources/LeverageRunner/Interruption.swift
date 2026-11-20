import Foundation
import LeverageKit

/// What the runner does after a failed tool run (plan §2.2, HD-5): ask the
/// provider's detector, retry a short rate limit in place, ask
/// `SignInStatus` when the output does not settle it, and decide between
/// "go on as milestone 2 does" and "this account stopped". It logs the
/// outcome's kind and nothing a tool printed.
struct Interruption: Sendable {
    /// What follows one failed run.
    enum Decision: Equatable, Sendable {
        /// Not an interruption: CL-22's failure, as milestone 2 treats it.
        case goOnAsBefore
        /// A short rate limit that names no window: run the tool again.
        case retryInPlace
        /// The account stopped: end the tool and the heartbeat, release
        /// nothing, and hand the report to `main`.
        case accountStopped(RunOutcome)
    }

    /// What a tool run came to once the interruption had its say.
    enum Result: Equatable, Sendable {
        case answered(ToolAnswer)
        /// CL-22's failure.
        case failed(ToolFailure)
        /// The account stopped; the report `main` prints.
        case accountStopped(RunEndReport)
    }

    /// The waits before the three retries of a short rate limit (HD-7).
    static let rateLimitWaits: [Duration] = []
    /// How long the status command may take.
    static let statusTimeLimit: Duration = .seconds(30)

    /// The seat's provider.
    let provider: Provider
    /// Whether the seat runs on a login of its own; a run with no
    /// credential detects nothing (HM-19).
    let hasCredential: Bool
    let waits: [Duration]
    let signInStatus: @Sendable () async -> SignInAnswer
    let log: Log?

    init(
        provider: Provider, hasCredential: Bool, waits: [Duration] = Interruption.rateLimitWaits,
        signInStatus: @escaping @Sendable () async -> SignInAnswer = { .noStatusCommand }, log: Log? = nil
    ) {
        self.provider = provider
        self.hasCredential = hasCredential
        self.waits = waits
        self.signInStatus = signInStatus
        self.log = log
    }

    /// The runner's: the seat's tool and account, with the credential the
    /// run is on, if any.
    static func runner(tool: ToolConfiguration, credentialID: UUID?, log: Log) -> Interruption {
        Interruption(provider: tool.provider, hasCredential: credentialID != nil, log: log)
    }

    /// The decision after `record`, the failed run that ended at `now`.
    func decide(after record: ToolRunRecord, at now: Date) async -> Decision {
        .goOnAsBefore
    }

    /// Runs `attempt` and settles a failure (not built yet).
    func run(for subject: LeaseSubject, _ attempt: @Sendable () async throws -> ToolRun) async throws -> Result {
        switch try await attempt() {
        case .answered(let answer): return .answered(answer)
        case .failed(let failure, _): return .failed(failure)
        }
    }
}
