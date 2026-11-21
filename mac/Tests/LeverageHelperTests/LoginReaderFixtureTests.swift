import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

struct LoginReaderFixtureTests {
    struct Reply: Decodable {
        struct Meta: Decodable {
            struct ExpectedReading: Decodable {
                let state: ReadingState
                let figures: [Figure]
                let resets: [Reset]?
            }

            let provider: Provider
            let kind: String
            let expect: ExpectedReading
            let now: Date?
            let fileExists: Bool?

            enum CodingKeys: String, CodingKey {
                case provider, kind, expect, now
                case fileExists = "file_exists"
            }
        }

        let meta: Meta
        let stdout: String?
        let session: [String: MethodReply]?
        let settings: JSONValue?

        struct MethodReply: Decodable {
            let result: JSONValue?
        }

        func result(for method: String) throws -> Data {
            guard let result = session?[method]?.result else { return Data() }
            return try LeverageJSON.encoder().encode(result)
        }

        static func load(_ url: URL) throws -> Reply {
            try LeverageJSON.decoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }

    @Test("every Claude and Codex usage reply matches its expected reading", arguments: [Provider.claude, .codex])
    func usageFixtures(provider: Provider) throws {
        let folder = StandIns.replies.appendingPathComponent(provider.rawValue, isDirectory: true)
        let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("usage-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!paths.isEmpty, "\(provider.rawValue)")
        for path in paths {
            let reply = try Reply.load(path)
            let filename = "\(provider.rawValue)/\(path.lastPathComponent)"
            #expect(reply.meta.provider == provider, "\(filename)")
            #expect(reply.meta.kind == "usage", "\(filename)")
            let reading: UsageReading
            if provider == .claude {
                reading = try claudeReading(reply)
            } else {
                reading = try CodexUsageParser.parse(
                    rateLimits: reply.result(for: "account/rateLimits/read"),
                    usage: reply.result(for: "account/usage/read"))
            }
            #expect(reading.state == reply.meta.expect.state, "\(filename)")
            #expect(reading.figures == reply.meta.expect.figures, "\(filename)")
            #expect(reading.resets == reply.meta.expect.resets, "\(filename)")
            #expect(reading.figures.allSatisfy { provider.figureLabels.contains($0.label) }, "\(filename)")
        }
    }

    @Test("Gemini and Grok have no login readers", arguments: [Provider.gemini, .grok])
    func providersWithoutReaders(provider: Provider) {
        #expect(UsageReaders.reader(for: provider) == nil)
    }

    private func claudeReading(_ reply: Reply) throws -> UsageReading {
        if let settings = reply.settings {
            let now = try #require(reply.meta.now)
            let data = reply.meta.fileExists == false ? Data() : try LeverageJSON.encoder().encode(settings)
            return UsageReading(state: .ok, resets: ClaudeResetCache.read(data: data, now: now))
        }
        let stdout = try #require(reply.stdout)
        return ClaudeUsageParser.parse(Data(stdout.utf8))
    }
}
