import Foundation
import LeverageKit

enum CodexAppServer {
    enum Method: String, CaseIterable {
        case initialize = "initialize"
        case account = "account/read"
        case rateLimits = "account/rateLimits/read"
        case usage = "account/usage/read"
    }

    struct UsageReplies {
        let rateLimits: Data
        let usage: Data
    }

    static func usage(_ account: ReaderAccount) async -> UsageReplies? { nil }
    static func account(_ account: ReaderAccount) async -> Data? { nil }
}
