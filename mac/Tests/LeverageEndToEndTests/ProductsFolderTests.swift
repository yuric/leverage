import Foundation
import Testing

// Where the end-to-end tests find the helper and the runner they start: the
// build's products folder, beside the test program. On macOS the program is
// inside a .xctest bundle. On Linux, Swift 6.4's SwiftPM builds the tests as
// a shared library with a runner program beside them, in the products folder
// (LeverageEndToEndTests.so and LeverageEndToEndTests-test-runner); older
// toolchains build one plain program named .xctest. These run without
// LEVERAGE_E2E, on every platform, because the first CI run on Linux showed
// the harness refusing its own test program there.
@Suite("The end-to-end tests' products folder")
struct ProductsFolderTests {
    @Test("on macOS it is the folder that holds the .xctest bundle")
    func bundle() throws {
        let program = URL(fileURLWithPath:
            "/b/.build/arm64-apple-macosx/debug/LeveragePackageTests.xctest/Contents/MacOS/LeveragePackageTests")
        #expect(try EndToEnd.productsFolder(forTestProgram: program).path
            == "/b/.build/arm64-apple-macosx/debug")
    }

    @Test("on Linux it is the folder of the tests' runner program")
    func linuxRunnerProgram() throws {
        let program = URL(fileURLWithPath:
            "/b/.build/x86_64-unknown-linux-gnu/debug/LeverageEndToEndTests-test-runner")
        #expect(try EndToEnd.productsFolder(forTestProgram: program).path
            == "/b/.build/x86_64-unknown-linux-gnu/debug")
    }

    @Test("on Linux it is the folder of the tests' shared library")
    func linuxSharedLibrary() throws {
        let program = URL(fileURLWithPath:
            "/b/.build/x86_64-unknown-linux-gnu/debug/LeverageEndToEndTests.so")
        #expect(try EndToEnd.productsFolder(forTestProgram: program).path
            == "/b/.build/x86_64-unknown-linux-gnu/debug")
    }

    @Test("on Linux it is the folder of a plain .xctest program")
    func linuxXCTestProgram() throws {
        let program = URL(fileURLWithPath:
            "/b/.build/x86_64-unknown-linux-gnu/debug/LeveragePackageTests.xctest")
        #expect(try EndToEnd.productsFolder(forTestProgram: program).path
            == "/b/.build/x86_64-unknown-linux-gnu/debug")
    }

    /// `swift test` builds the package's programs beside the tests, so the
    /// helper the end-to-end tests start is found in this run's own folder.
    @Test("this test program's own products folder is found and holds the helper")
    func ownFolder() throws {
        let helper = try EndToEnd.productsFolder().appendingPathComponent("LeverageHelper")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    }
}
