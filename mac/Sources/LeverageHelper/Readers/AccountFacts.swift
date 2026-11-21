import LeverageKit

struct AccountFacts: Sendable {
    struct Result: Sendable {
        var plan: String?
        var email: String?
    }

    typealias Read = @Sendable (ReaderAccount) async -> Result

    var read: Read = { _ in Result() }
}
