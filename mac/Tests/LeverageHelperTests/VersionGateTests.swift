import Testing

@testable import LeverageHelper

@Suite("Reader version gate")
struct VersionGateTests {
    @Test func comparesExactlyAfterCutting() {
        #expect(VersionGate.accepts("2.1.325 (Claude Code)", testedVersions: ["2.1.325"]))
        #expect(VersionGate.accepts("codex-cli 0.169.0", testedVersions: ["Codex 0.169.0"]))
        #expect(!VersionGate.accepts("2.1.3250", testedVersions: ["2.1.325"]))
        #expect(!VersionGate.accepts("2.1.325.1", testedVersions: ["2.1.325"]))
        #expect(!VersionGate.accepts("unknown", testedVersions: ["unknown"]))
        #expect(!VersionGate.accepts("2.1.325", testedVersions: []))
    }
}
