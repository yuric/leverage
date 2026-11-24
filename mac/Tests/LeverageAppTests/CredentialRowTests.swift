import Foundation
import LeverageKit
import Testing

@testable import LeverageApp

@Suite("CredentialRow")
struct CredentialRowTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_600)
    private let id = UUID()

    private func row(
        kind: CredentialKind = .login, provider: Provider = .codex, state: CredentialState = .active,
        reading: ReadingState = .ok, secondsOld: TimeInterval = 0, version: String? = nil,
        testedVersions: [String]? = nil, figures: [Figure] = [], resets: [Reset]? = nil, model: String? = nil
    ) -> CredentialRow {
        CredentialRow(
            CredentialWithReading(
                credential: Credential(id: id, kind: kind, provider: provider, name: "Work", state: state,
                                       position: 1, model: model),
                reading: CredentialReading(credentialID: id, observedAt: now.addingTimeInterval(-secondsOld),
                                           state: reading, toolVersion: version, figures: figures, resets: resets)),
            now: now, calendar: AgentFixtures.utc, locale: AgentFixtures.usEnglish, testedVersions: testedVersions)
    }

    @Test("each supplied figure has one tile and zero remains zero")
    func figures() throws {
        let later = now.addingTimeInterval(86_400)
        let figures = [
            Figure(label: "Five-hour session", kind: .limit, window: .fiveHour, percentUsed: 0, resetAt: later, value: nil),
            Figure(label: "Lifetime tokens", kind: .activity, window: nil, percentUsed: nil, resetAt: nil, value: .number(0)),
            Figure(label: "Reported value", kind: .allowance, window: nil, percentUsed: nil, resetAt: nil, value: .string("2 / 3")),
        ]
        let tiles = row(figures: figures).figures
        #expect(tiles.map(\.label) == figures.map(\.label))
        #expect(tiles.map(\.value) == ["0% used", "0", "2 / 3"])
        let first = try #require(tiles.first)
        let at = now
        let clock = ResetClock(now: { at }, calendar: AgentFixtures.utc, locale: AgentFixtures.usEnglish)
        #expect(first.resetLine == "Resets \(ResetTime.text(for: later, clock: clock)).")
    }

    @Test("resets distinguish missing, empty and zero, and tokens omit the line")
    func resets() {
        #expect(row().resetsLine == "Available resets: —")
        #expect(row(resets: []).resetsLine == "Available resets: 0")
        #expect(row(resets: [Reset(count: 0, kind: .full, expiresAt: nil)]).resetsLine == "Available resets: 0")
        #expect(row(resets: [Reset(count: 2, kind: .full, expiresAt: nil)]).resetsLine == "Available resets: 2 full")
        #expect(row(kind: .apiToken, provider: .openaiApi, resets: []).resetsLine == nil)
    }

    @Test("reading age appears only when strictly older than ten minutes")
    func age() {
        #expect(row(secondsOld: 600).ageLine == nil)
        #expect(row(secondsOld: -1).ageLine == nil)
        #expect(row(secondsOld: 601).ageLine != nil)
    }

    @Test("unavailable distinguishes a reader missing, a version mismatch and a temporary failure")
    func unavailable() {
        #expect(row(provider: .gemini, reading: .unavailable).readingLine ==
                "Unavailable. Leverage does not read usage for Gemini yet.")
        #expect(row(reading: .unavailable, version: "codex 9.8.7 (built)", testedVersions: ["v0.1.2"]).readingLine ==
                "Unavailable. Leverage has not been checked with Codex 9.8.7 yet.")
        #expect(row(reading: .unavailable, version: "codex 0.1.2 (built)", testedVersions: ["v0.1.2"]).readingLine ==
                "Unavailable right now.")
        #expect(row(reading: .unavailable, testedVersions: ["v0.1.2"]).readingLine == "Unavailable right now.")
        #expect(row(reading: .unavailable, version: "unknown", testedVersions: ["v0.1.2"]).readingLine ==
                "Unavailable right now.")
        #expect(row(kind: .apiToken, provider: .openrouter, reading: .unavailable).readingLine == "Unavailable right now.")
    }

    @Test("a signed-out reading leaves a login's status dot alone")
    func signedOutReading() {
        let active = row(reading: .signedOut)
        #expect(!active.isSignedOut)
        #expect(active.usage.isEmpty)
        #expect(active.readingLine == "Looked signed out when last read. Choose Verify to check.")
        #expect(row(state: .signedOut).isSignedOut)
    }

    @Test("a stopped token says to remove and add it again and has no sign-in action or model")
    func token() {
        let token = row(kind: .apiToken, provider: .openrouter, state: .signedOut, model: "Example")
        #expect(token.usage == "This token no longer works. Remove it and add it again.")
        #expect(token.tokenLine == "Not used for work yet. Leverage checks it and shows what its provider reports.")
        #expect(token.modelLine == nil)
        #expect(token.actions == [.rename, .verify, .remove])
    }

    @Test("logins have four menu items and show the handoff model only when set")
    func login() {
        #expect(row().actions == [.rename, .verify, .signInAgain, .remove])
        #expect(row().modelLine == nil)
        #expect(row(model: "Example").modelLine == "Uses Example when work moves here from another provider")
    }
}
