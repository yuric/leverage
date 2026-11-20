import Foundation

/// The one thing `SignInStatus` gives back.
public enum SignInAnswer: String, CaseIterable, Sendable {
    case signedIn = "signed in"
    case signedOut = "signed out"
    /// The provider has no status command (Antigravity): the answering
    /// check, a test prompt, is its sign-in check instead (PV-3).
    case noStatusCommand = "no status command"
    /// The status command could not start, or passed its time limit: it
    /// said nothing either way.
    case couldNotTell = "could not tell"
}

/// "Is this account signed in", from the catalog's status command (plan
/// PV-3, HD-5). The runner asks it after a failed run whose output settled
/// nothing; the helper asks it for the add and verify checks. One copy for
/// both programs (AR-002).
///
/// A status command prints the account's email, organisation and plan
/// (`inventory-providers.md` §5). Its output is held in memory, read for the
/// one signed-in field and dropped: only the answer leaves this function,
/// and nothing of the output is logged, returned or kept in an error.
public enum SignInStatus {
    /// Runs the entry's status command with exactly `environment` (built by
    /// `ProviderCatalog.toolEnvironment`) and reads it the catalog's way. A
    /// command that cannot start, or that passes `timeLimit`, could not
    /// tell: the runner then keeps milestone 2's failure count (CL-22)
    /// rather than report a sign-out, and the helper's checks read it as
    /// not signed in, as milestone 2 did. `log` is told the answer and how
    /// the command ended, and nothing it printed.
    public static func check(
        _ entry: ProviderEntry, toolPath: String, environment: [String: String],
        timeLimit: Duration, log: Log? = nil
    ) async -> SignInAnswer {
        let check = entry.status.value
        guard let arguments = check.arguments, check.reading != .testPrompt else {
            log?.info("sign-in status of \(entry.id): \(SignInAnswer.noStatusCommand.rawValue)")
            return .noStatusCommand
        }
        let answer: SignInAnswer
        let ending: String
        do {
            let result = try await Subprocess.run(SubprocessRequest(
                executable: toolPath, arguments: arguments, environment: environment,
                timeLimit: timeLimit, gracePeriod: .seconds(2)))
            if let endedBy = result.endedBy {
                answer = .couldNotTell
                ending = "ended by \(endedBy)"
            } else {
                answer = reads(check.reading, result) ? .signedIn : .signedOut
                ending = "\(result.termination)"
            }
        } catch {
            // A SubprocessError names the program and a system call, never
            // anything the tool printed.
            answer = .couldNotTell
            ending = "could not start: \(error)"
        }
        log?.info("sign-in status of \(entry.id): \(answer.rawValue) (status command \(ending))")
        return answer
    }

    /// What a status command's result says, by the catalog's reading.
    static func answer(_ reading: StatusCheck.Reading, _ result: SubprocessResult) -> SignInAnswer {
        reads(reading, result) ? .signedIn : .signedOut
    }

    /// What a status command's result says, by the catalog's reading.
    static func reads(_ reading: StatusCheck.Reading, _ result: SubprocessResult) -> Bool {
        switch reading {
        case .jsonField(let field):
            let object = try? JSONDecoder().decode(JSONValue.self, from: result.standardOutput)
            return object?[field] == .bool(true)
        case .exitCode:
            return result.termination == .exited(0)
        case .signedOutText(let text):
            let output = String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
            return result.termination == .exited(0) && !output.contains(text)
        case .testPrompt:
            return false
        }
    }
}
