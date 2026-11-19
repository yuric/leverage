import Foundation
import Testing
@testable import LeverageKit

@Suite("Configuration")
struct ConfigurationTests {
    @Test("defaults the API base URL to the loopback port compose publishes")
    func defaultBaseURL() {
        let configuration = Configuration(environment: [:])
        #expect(configuration.apiBaseURL.absoluteString == "http://127.0.0.1:3000")
    }

    @Test("reads the API base URL from LEVERAGE_API_URL")
    func environmentBaseURL() {
        let configuration = Configuration(
            environment: ["LEVERAGE_API_URL": "http://example.test:8080"])
        #expect(configuration.apiBaseURL.absoluteString == "http://example.test:8080")
    }

    @Test("falls back to the default when LEVERAGE_API_URL is not an http URL")
    func invalidBaseURL() {
        let configuration = Configuration(environment: ["LEVERAGE_API_URL": "not a url"])
        #expect(configuration.apiBaseURL.absoluteString == "http://127.0.0.1:3000")
    }
}

@Suite("Health line")
struct HealthLineTests {
    @Test("describes a healthy API")
    func healthy() {
        let line = healthLine(for: .success(Health(status: "ok", version: "1.2.3")))
        #expect(line == "API: ok (version 1.2.3)")
    }

    @Test("describes an API that answered with an error status")
    func unhealthy() {
        let line = healthLine(for: .failure(LeverageClientError.unexpectedStatus(500)))
        #expect(line == "API: unavailable (HTTP 500)")
    }

    @Test("describes an API that could not be reached")
    func unreachable() {
        let line = healthLine(for: .failure(URLError(.cannotConnectToHost)))
        #expect(line.hasPrefix("API: unreachable ("))
    }
}
