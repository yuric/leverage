import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

// A placeholder until WP12: proves the helper lane builds and links its
// target, LeverageKit and LeverageTestSupport.
@Suite("LeverageHelper target")
struct HelperTargetTests {
    @Test("the helper's tests reach the stand-in tools")
    func standInsReachable() {
        for name in StandIns.toolNames {
            #expect(FileManager.default.isExecutableFile(
                atPath: StandIns.sourceFolder.appendingPathComponent("bin/\(name)").path))
        }
    }
}
