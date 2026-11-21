import Foundation
import LeverageKit

struct ProviderHTTP: Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct Failure: Error, Equatable {
        enum Code: String, Sendable {
            case invalidOverride, unsupportedProvider, invalidTestToken, redirect, bodyTooLarge, unreachable, timedOut
        }

        let host: String
        let code: Code
    }

    init() {}

    init(executableURL: URL, environment: [String: String], protocolClasses: [AnyClass]? = nil) throws {}

    func get(_ provider: Provider, token: String, timeout: Duration) async throws -> Response {
        throw Failure(host: "", code: .unreachable)
    }
}
