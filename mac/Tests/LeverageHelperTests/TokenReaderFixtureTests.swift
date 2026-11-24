import Foundation
import LeverageKit
import LeverageTestSupport
import Testing
@testable import LeverageHelper

struct TokenReaderFixtureTests {
    private struct ExpectedReading: Decodable {
        let state: ReadingState
        let figures: [Figure]
        let resets: [Reset]?
    }

    private struct Reply: Decodable {
        struct Meta: Decodable {
            let provider: Provider
            let basis: String
            let kind: String
            let expect: ExpectedReading
        }

        let meta: Meta
        let status: Int
        let headers: [String: String]
        let body: JSONValue
    }

    @Test("each documentation reply matches its expected state, figures and resets",
          arguments: Provider.allCases.filter { $0.kind == .apiToken })
    func documentedReplies(provider: Provider) throws {
        let folder = StandIns.replies.appendingPathComponent(provider.rawValue, isDirectory: true)
        let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!paths.isEmpty, "\(provider.rawValue)")
        var checked = 0
        for path in paths {
            let reply = try LeverageJSON.decoder().decode(Reply.self, from: Data(contentsOf: path))
            guard reply.meta.basis == "made_from_documentation" else { continue }
            checked += 1
            let filename = "\(provider.rawValue)/\(path.lastPathComponent)"
            #expect(reply.meta.provider == provider, "\(filename)")
            #expect(reply.meta.kind == "usage", "\(filename)")
            let reading = TokenReaders.read(
                provider: provider, status: reply.status, headers: reply.headers,
                body: try LeverageJSON.encoder().encode(reply.body))
            #expect(reading.state == reply.meta.expect.state, "\(filename)")
            #expect(reading.figures == reply.meta.expect.figures, "\(filename)")
            #expect(reading.resets == reply.meta.expect.resets, "\(filename)")
            #expect(reading.figures.allSatisfy { provider.figureLabels.contains($0.label) }, "\(filename)")
        }
        #expect(checked > 0, "\(provider.rawValue)")
    }

    @Test("an authorization failure is signed out and other HTTP failures are unavailable",
          arguments: Provider.allCases.filter { $0.kind == .apiToken })
    func statusCodes(provider: Provider) {
        for status in [401, 403, 204, 302, 429, 500] {
            let reading = TokenReaders.read(provider: provider, status: status, headers: [:], body: Data())
            let expected: ReadingState = [401, 403].contains(status) ? .signedOut : .unavailable
            #expect(reading.state == expected, "\(provider.rawValue): \(status)")
            #expect(reading.figures.isEmpty)
            #expect(reading.resets == nil)
        }
    }

    @Test("a success status with a body outside the reader's envelope is unavailable",
          arguments: Provider.allCases.filter { $0.kind == .apiToken })
    func wrongEnvelope(provider: Provider) {
        for body in ["<invalid>", "[]", #"{"data":false,"models":false}"#] {
            if provider == .grokApi && body.first == "{" { continue }
            let reading = TokenReaders.read(
                provider: provider, status: 200, headers: [:], body: Data(body.utf8))
            #expect(reading.state == .unavailable, "\(provider.rawValue): \(body)")
            #expect(reading.figures.isEmpty)
        }
    }

    @Test("OpenRouter omits invalid figures, keeps real zero and rounds the derived percent to one decimal")
    func spendingFigures() {
        let body = #"""
        {"data":{"limit":3,"limit_remaining":2,"limit_reset":"2027-01-01T00:00:00Z",
          "usage":9,"usage_daily":false,"usage_weekly":0,"usage_monthly":"1"}}
        """#
        let reading = TokenReaders.read(provider: .openrouter, status: 200, headers: [:], body: Data(body.utf8))
        #expect(reading.state == .ok)
        #expect(reading.figures == [
            Figure(label: "Spending limit", kind: .limit, window: .spend, percentUsed: 33.3,
                   resetAt: Date(timeIntervalSince1970: 1_798_761_600), value: nil),
            Figure(label: "Left, in US dollars", kind: .allowance, window: nil, percentUsed: nil,
                   resetAt: nil, value: .number(2)),
            Figure(label: "Use this week, in US dollars", kind: .activity, window: nil, percentUsed: nil,
                   resetAt: nil, value: .number(0)),
        ])
    }

    @Test("an unusable limit, remaining amount or reset omits only the spending limit", arguments: [
        #"{"limit":0,"limit_remaining":0,"usage_daily":1}"#,
        #"{"limit":1,"limit_remaining":2,"usage_daily":1}"#,
        #"{"limit":1,"limit_remaining":0,"limit_reset":"soon","usage_daily":1}"#,
    ])
    func unusableLimit(key: String) {
        let reading = TokenReaders.read(
            provider: .openrouter, status: 200, headers: [:], body: Data(#"{"data":\#(key)}"#.utf8))
        #expect(reading.state == .ok)
        #expect(!reading.figures.contains { $0.kind == .limit })
        #expect(reading.figures.last?.value == .number(1))
    }

    @Test("a request count is a nonnegative whole number from the provider's header")
    func requestCounts() throws {
        let header = try #require(TokenReaders.responseHeaders(for: .openaiApi).first)
        #expect(TokenReaders.responseHeaders(for: .openaiApi) == ["x-ratelimit-remaining-requests"])
        #expect(TokenReaders.responseHeaders(for: .claudeApi) == ["anthropic-ratelimit-requests-remaining"])
        let body = Data(#"{"object":"list","data":[]}"#.utf8)
        for value in ["-1", "1.5", "nan", "1, 2", "9007199254740993"] {
            let reading = TokenReaders.read(provider: .openaiApi, status: 200, headers: [header: value], body: body)
            #expect(reading.state == .ok)
            #expect(reading.figures.isEmpty, "\(value)")
        }
        let zero = TokenReaders.read(
            provider: .openaiApi, status: 200, headers: [header: "0"], body: body)
        #expect(zero.figures.first?.value == .number(0))
    }

    @Test("Grok's three documented block flags each make its token check fail",
          arguments: ["api_key_blocked", "api_key_disabled", "team_blocked"])
    func grokBlocked(flag: String) {
        #expect(TokenReaders.grokBlocked(in: Data(#"{"\#(flag)":true}"#.utf8)) == true)
        #expect(TokenReaders.grokBlocked(in: Data(#"{"\#(flag)":false}"#.utf8)) == false)
        #expect(TokenReaders.grokBlocked(in: Data(#"{"\#(flag)":"false"}"#.utf8)) == nil)
    }
}
