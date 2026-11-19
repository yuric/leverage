import Foundation
import LeverageKit

/// When a command's idempotency key is spent (IN-8).
enum CommandKey {
    /// Whether the server answered the call that threw `error`. A command is
    /// sent again under the same key only while it has not been answered: a
    /// network failure or a pending answer leaves it unanswered, and a refusal
    /// or a transport error is an answer.
    static func wasAnswered(_ error: any Error) -> Bool {
        switch error {
        case is URLError: false
        case LeverageClientError.pending: false
        default: true
        }
    }
}
