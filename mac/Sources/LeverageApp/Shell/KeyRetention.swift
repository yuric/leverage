import Foundation
import LeverageKit

extension IdempotencyKey {
    /// Whether a command's key is kept for the next press after the command
    /// failed with `error`. Only a request whose answer is unknown keeps it:
    /// a network failure, or a 5xx, may have reached the server, so a press
    /// again sends the same command and the server answers it once (PRD
    /// L221). A refusal (409), or a body or a sign-in the API turned back
    /// (400, 401, 404, 422), was answered: the server keeps that answer
    /// under the key, so a press again gets a new key and is asked again
    /// (milestone 4 review, finding 16).
    static func isKept(after error: any Error) -> Bool {
        switch error {
        case LeverageClientError.refused: false
        case is TransportError: false
        case LeverageClientError.unexpectedStatus(let status): status >= 500
        default: true
        }
    }
}
