import Foundation

/// The version of the Mac side: LeverageKit, the helper and the app.
public let leverageMacVersion = "0.1.0"

/// One line describing the API's health, shown by the helper and the app.
public func healthLine(for result: Result<Health, any Error>) -> String {
    switch result {
    case .success(let health):
        return "API: \(health.status) (version \(health.version))"
    case .failure(LeverageClientError.unexpectedStatus(let status)):
        return "API: unavailable (HTTP \(status))"
    case .failure(LeverageClientError.invalidBody):
        return "API: unavailable (unreadable answer)"
    case .failure(let error):
        return "API: unreachable (\(error.localizedDescription))"
    }
}
