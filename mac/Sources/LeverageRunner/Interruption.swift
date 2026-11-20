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
    static let rateLimitWaits: [Duration] = [.seconds(5), .seconds(15), .seconds(45)]
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
    /// run is on, if any. The status command runs with the tool's own environment (CL-10), so
    /// it reads the same account folder as the run.
    static func runner(tool: ToolConfiguration, credentialID: UUID?, log: Log) -> Interruption {
        Interruption(
            provider: tool.provider, hasCredential: credentialID != nil,
            signInStatus: {
                await SignInStatus.check(
                    tool.entry, toolPath: tool.toolPath, environment: tool.toolEnvironment,
                    timeLimit: Interruption.statusTimeLimit, log: log)
            },
            log: log)
    }

    /// The decision after `record`, the failed run that ended at `now`. A
    /// run with no credential, or of a provider with no detector, goes on
    /// as before; otherwise the detector reads the outputs, and a failure
    /// they do not settle is a sign-out only when the status command says
    /// signed out (HD-5).
    func decide(after record: ToolRunRecord, at now: Date) async -> Decision {
        guard hasCredential, let detector = Detectors.detector(for: provider) else { return .goOnAsBefore }
        let outcome = detector.outcome(of: record, at: now)
        log?.info("the failed tool run reads as \(outcome.name)")
        switch outcome {
        case .limit, .signedOut:
            return .accountStopped(outcome)
        case .rateLimited:
            return .retryInPlace
        case .failed:
            switch await signInStatus() {
            case .signedOut: return .accountStopped(.signedOut)
            // A status command that said nothing is no sign-out: the run
            // counts as a failure, as in milestone 2 (CL-22).
            case .signedIn, .noStatusCommand, .couldNotTell: return .goOnAsBefore
            }
        }
    }

    /// Runs `attempt`, the tool's run for `subject`. A short rate limit is
    /// run again after each of `waits` (the caller's heartbeat runs on
    /// meanwhile) and is then a failure; a limit or a sign-out is the
    /// account's stop, with the report `main` prints (HD-6, HD-7).
    func run(for subject: InterruptedWork, _ attempt: @Sendable () async throws -> ToolRun) async throws -> Result {
        var retries = 0
        while true {
            let failure: ToolFailure
            let record: ToolRunRecord
            switch try await attempt() {
            case .answered(let answer):
                return .answered(answer)
            case .failed(let failed, nil):
                return .failed(failed)
            case .failed(let failed, let run?):
                failure = failed
                record = run
            }
            let observedAt = Date()
            switch await decide(after: record, at: observedAt) {
            case .goOnAsBefore:
                return .failed(failure)
            case .accountStopped(let outcome):
                return .accountStopped(Self.report(outcome, of: subject, at: observedAt))
            case .retryInPlace:
                guard retries < waits.count else {
                    log?.info("the short rate limit outlasted \(waits.count) retries")
                    return .failed(failure)
                }
                try await Task.sleep(for: waits[retries])
                retries += 1
            }
        }
    }

    /// The report of an account that stopped: the kind, the window and the
    /// reset time the reply stated, the work, and when it was seen. The
    /// tool's version is left to the helper, which found the tool and knows
    /// it (HD-6).
    static func report(_ outcome: RunOutcome, of subject: InterruptedWork, at observedAt: Date) -> RunEndReport {
        let taskID: UUID?
        let reviewID: UUID?
        switch subject {
        case .task(let id): (taskID, reviewID) = (id, nil)
        case .review(let id): (taskID, reviewID) = (nil, id)
        case .job: (taskID, reviewID) = (nil, nil)
        }
        if case .limit(let window, let resetAt) = outcome {
            return RunEndReport(
                kind: .limit, window: window, resetAt: resetAt, taskID: taskID, reviewID: reviewID, toolVersion: nil,
                observedAt: observedAt)
        }
        return RunEndReport(
            kind: .signedOut, window: nil, resetAt: nil, taskID: taskID, reviewID: reviewID, toolVersion: nil,
            observedAt: observedAt)
    }
}
