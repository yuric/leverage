import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

// A placeholder until WP19. The end-to-end tests run only with
// LEVERAGE_E2E=1 (scripts/e2e_core_loop.sh sets it), because they need the
// API in its containers.
@Suite("End to end", .enabled(if: ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "1"))
struct EndToEndSwitchTests {
    @Test("the stand-ins can be copied into a folder of the test's own")
    func standInsCopy() throws {
        let folder = try TemporaryFolder(prefix: "e2e-placeholder")
        defer { folder.remove() }
        let tools = try StandIns.copy(into: folder.url)
        #expect(FileManager.default.isExecutableFile(atPath: tools.tool("claude").path))
    }
}
