import LeverageKit

enum AddTokenCopy: OwnerFacingCopy {
    case loginProviders, tokenProviders, stepName, nameLabel, tokenLabel, add
    case nameContainsToken, checkWorks
    case helperNotRunning
    case failRejected, failUnreachable, failTimedOut, failMissing, failStore, failProvider, failAnswer

    var text: String {
        switch self {
        case .loginProviders: "Logins"
        case .tokenProviders: "API tokens"
        case .stepName: "Step 2 of 2. Name it and paste the token."
        case .nameLabel: "Name for this {provider} token"
        case .tokenLabel: "API token"
        case .add: "Add"
        case .nameContainsToken: "Give it a name that does not include the token."
        case .checkWorks: "The token works"
        case .helperNotRunning: "Agents are not running on this Mac, so Leverage cannot check the token."
        case .failRejected: "{provider} rejected this token."
        case .failUnreachable: "{provider} could not be reached. Check this Mac's internet connection."
        case .failTimedOut: "{provider} took too long to check the token."
        case .failStore: "Leverage could not access this Mac’s Keychain. Check Keychain access and try again."
        case .failProvider: "Check the token’s provider and add it again. Remove the old token first if it is listed."
        case .failAnswer: "{provider} could not complete the token check."
        case .failMissing: "This token is missing on this Mac."
        }
    }

    static func failureLine(for failure: HelperCheckFailure?, provider: String) -> String {
        let copy: Self
        switch failure {
        case .rejected: copy = .failRejected
        case .unreachable: copy = .failUnreachable
        case .timedOut: copy = .failTimedOut
        case .tokenStoreUnavailable: copy = .failStore
        case .providerMismatch: copy = .failProvider
        case .noAnswer: copy = .failAnswer
        case .notSignedIn: copy = .failMissing
        default: return CredentialsCopy.failedGeneric.text
        }
        return copy.filled(["provider": provider])
    }
}
