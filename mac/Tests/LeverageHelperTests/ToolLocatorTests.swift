import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// Where the helper looks for a provider's tool (PV-3), and the status
/// readings of PV-3, against the stand-ins.
@Suite("Tool locator and status", .timeLimit(.minutes(Patience.minutes(1))))
struct ToolLocatorTests {
    @Test("with a tool folder set, nothing outside it is looked at, not even PATH")
    func onlyTheToolFolder() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        rig.settings.environment["PATH"] = rig.tools.bin.path + ":/usr/bin:/bin"
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        let claude = ProviderCatalog.entry(for: "claude")!

        #expect(locator.searchFolders(for: claude) == [rig.toolDir.path])
        #expect(locator.find(claude) == nil)
        #expect(await locator.locate(claude) == nil)
    }

    @Test("without one, the catalog's folders come first and then PATH, in order")
    func catalogThenPath() throws {
        let rig = try HelperRig()
        rig.settings.toolDir = nil
        rig.settings.environment["PATH"] = "/somewhere/bin:/usr/bin:/bin"
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        let codex = ProviderCatalog.entry(for: "codex")!

        let folders = locator.searchFolders(for: codex)

        #expect(Array(folders.prefix(5)) == ProviderCatalog.searchFolders(
            for: "codex", home: rig.home.path, supportFolder: rig.support.path, toolDir: nil))
        #expect(Array(folders.suffix(3)) == ["/somewhere/bin", "/usr/bin", "/bin"])
    }

    @Test("a found tool answers its version", arguments: ["claude", "codex", "gemini", "grok"])
    func version(provider: String) async throws {
        let rig = try HelperRig()
        let entry = ProviderCatalog.entry(for: provider)!

        let found = try #require(await ToolLocator(settings: rig.settings, timings: fastTimings).locate(entry))

        #expect(found.path == rig.tools.tool(entry.toolName).path)
        #expect(!found.version.isEmpty)
    }

    @Test("signed in or not, read the way PV-3 says, per provider", arguments: ["claude", "codex", "grok"])
    func status(provider: String) async throws {
        let rig = try HelperRig()
        let entry = ProviderCatalog.entry(for: provider)!
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        let tool = try #require(await locator.locate(entry))
        let folder = entry.accountFolderVariable.value == nil ? nil : try rig.folders.createFresh(for: UUID())
        let status = ToolStatus(locator: locator, prober: FixedPrompt(answer: false), settings: rig.settings)

        #expect(await !status.isSignedIn(entry, tool: tool, accountFolder: folder))
        try rig.tools.signIn(entry.toolName, accountFolder: folder)
        #expect(await status.isSignedIn(entry, tool: tool, accountFolder: folder))
    }

    @Test("a status command that cannot start is not signed in, for the add and verify checks as before")
    func statusCouldNotTell() async throws {
        let rig = try HelperRig()
        let entry = ProviderCatalog.entry(for: "claude")!
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        let missing = LocatedTool(path: rig.toolDir.appendingPathComponent("no-such-tool").path, version: "0.0.0")
        let folder = try rig.folders.createFresh(for: UUID())

        #expect(await !ToolStatus(locator: locator, prober: FixedPrompt(answer: true), settings: rig.settings)
            .isSignedIn(entry, tool: missing, accountFolder: folder))
    }

    @Test("Gemini's sign-in is read by the test prompt")
    func geminiStatus() async throws {
        let rig = try HelperRig()
        let entry = ProviderCatalog.entry(for: "gemini")!
        let locator = ToolLocator(settings: rig.settings, timings: fastTimings)
        let tool = try #require(await locator.locate(entry))

        #expect(await ToolStatus(locator: locator, prober: FixedPrompt(answer: true), settings: rig.settings)
            .isSignedIn(entry, tool: tool, accountFolder: nil))
        #expect(await !ToolStatus(locator: locator, prober: FixedPrompt(answer: false), settings: rig.settings)
            .isSignedIn(entry, tool: tool, accountFolder: nil))
    }
}
