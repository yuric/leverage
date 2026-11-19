import Foundation
import LeverageKit
import Testing

@testable import LeverageAppServices

@Suite("SupportFolder")
struct SupportFolderTests {
    @Test("defaults to Application Support/leverage in the home folder")
    func defaultFolder() {
        let folder = SupportFolder(environment: [:], home: URL(fileURLWithPath: "/Users/someone"))
        #expect(folder.url.path == "/Users/someone/Library/Application Support/leverage")
    }

    @Test("an absolute LEVERAGE_SUPPORT_DIR replaces it; a relative one is ignored")
    func override() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(SupportFolder(environment: ["LEVERAGE_SUPPORT_DIR": "/tmp/smoke"], home: home).url.path
            == "/tmp/smoke")
        #expect(SupportFolder(environment: ["LEVERAGE_SUPPORT_DIR": "smoke"], home: home).url.path
            == "/Users/someone/Library/Application Support/leverage")
    }
}
