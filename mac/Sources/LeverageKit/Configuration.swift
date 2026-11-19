import Foundation

/// The Mac side's settings, read from the process environment in one place.
public struct Configuration: Sendable {
    /// Where the API is served when `LEVERAGE_API_URL` is not set: the
    /// loopback port that `compose.yaml` publishes.
    public static let defaultAPIBaseURL = URL(string: "http://127.0.0.1:3000")!

    public let apiBaseURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let value = environment["LEVERAGE_API_URL"],
           let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host() != nil {
            apiBaseURL = url
        } else {
            apiBaseURL = Self.defaultAPIBaseURL
        }
    }
}
