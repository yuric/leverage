import Foundation

public enum SignInAnswer: String, CaseIterable, Sendable {
    case signedIn = "signed in"
    case signedOut = "signed out"
    case noStatusCommand = "no status command"
}

public enum SignInStatus {
    public static func check(
        _ entry: ProviderEntry, toolPath: String, environment: [String: String],
        timeLimit: Duration, log: Log? = nil
    ) async -> SignInAnswer {
        .signedOut
    }

    static func reads(_ reading: StatusCheck.Reading, _ result: SubprocessResult) -> Bool { false }
}
