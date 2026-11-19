import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageHelper

/// Installing a provider's tool with no terminal (L603, L715, PV-5). No test
/// runs a real installer or downloads anything: the download is a parameter,
/// and the tests hand over the stand-in installer and the stand-in archive.
@Suite("Tool installer", .timeLimit(.minutes(Patience.minutes(1))))
struct ToolInstallerTests {
    private let claude = ProviderCatalog.entry(for: "claude")!

    /// A download that records the address it was asked for and hands over
    /// a local file instead.
    final class Downloads: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [URL] = []
        let file: URL
        init(file: URL) { self.file = file }
        var addresses: [URL] { lock.withLock { asked } }
        var fetch: ToolInstaller.Fetch {
            { [self] address, _ in
                lock.withLock { asked.append(address) }
                return file
            }
        }
    }

    @Test("a script installer is fetched from its catalog address and run with its shell")
    func installsFromScript() async throws {
        let rig = try HelperRig()
        let downloads = Downloads(file: rig.tools.installer)
        let installer = ToolInstaller(settings: rig.settings, timings: fastTimings, fetch: downloads.fetch)

        try await installer.install(claude, from: claude.installer.value!)

        #expect(downloads.addresses == [URL(string: "https://claude.ai/install.sh")!])
        let installed = rig.home.appendingPathComponent(".local/bin/claude")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        let log = try String(contentsOf: rig.tools.state.appendingPathComponent("installer.log"), encoding: .utf8)
        #expect(log.contains("installed claude"))
    }

    @Test("an archive is unpacked into the support folder, where the tool is then found")
    func installsFromArchive() async throws {
        let rig = try HelperRig()
        let downloads = Downloads(file: rig.tools.archive)
        let archive = Installer(
            kind: .archive(program: "standin-tool"),
            url: URL(string: "https://downloads.example.test/standin-tool.tar.gz")!,
            allowedHosts: ["downloads.example.test"])
        let installer = ToolInstaller(settings: rig.settings, timings: fastTimings, fetch: downloads.fetch)

        try await installer.install(claude, from: archive)

        let tool = rig.support.appendingPathComponent("tools/claude/claude")
        #expect(FileManager.default.isExecutableFile(atPath: tool.path))
        var settings = rig.settings
        settings.toolDir = nil
        settings.environment["PATH"] = "/usr/bin:/bin"
        settings.environment["HOME"] = rig.home.path
        let locator = ToolLocator(settings: settings, timings: fastTimings)
        #expect(locator.searchFolders(for: claude).first == rig.support.appendingPathComponent("tools/claude").path)
        let found = await locator.locate(claude)
        #expect(found?.path == tool.path)
        #expect(found?.version == "standin-tool 0.0.1 (from an archive)")
    }

    @Test(
        "an address that is not HTTPS on a host the catalog lists is refused, and nothing is fetched",
        arguments: [
            "http://claude.ai/install.sh", "https://claude.ai.example.test/install.sh",
            "https://user@claude.ai/install.sh", "https://claude.ai:8443/install.sh", "file:///tmp/install.sh",
        ])
    func refusesAddress(address: String) async throws {
        let rig = try HelperRig()
        let downloads = Downloads(file: rig.tools.installer)
        let installer = ToolInstaller(settings: rig.settings, timings: fastTimings, fetch: downloads.fetch)
        let wrong = Installer(
            kind: .script(shell: "/bin/bash"), url: URL(string: address)!, allowedHosts: ["claude.ai"])

        await #expect(throws: ToolInstaller.Failure.refusedAddress) {
            try await installer.install(claude, from: wrong)
        }
        #expect(downloads.addresses.isEmpty)
    }

    @Test("the installer script gets an allow-listed environment: no leverage token")
    func scriptEnvironment() throws {
        let rig = try HelperRig()
        let installer = ToolInstaller(settings: rig.settings, timings: fastTimings)

        let request = installer.scriptRequest(shell: "/bin/bash", script: rig.tools.installer)

        #expect(request.executable == "/bin/bash")
        #expect(request.arguments == [rig.tools.installer.path])
        #expect(Set(request.environment.keys).isSubset(of: ["PATH", "HOME", "TMPDIR", "LANG", "USER"]))
        #expect(request.environment["HOME"] == rig.home.path)
        #expect(!request.environment.values.contains { $0.contains("lv") && $0.contains("_madeUp") })
        #expect(request.timeLimit == fastTimings.installLimit)
    }

    @Test("a failing installer script is a failed install")
    func failingScript() async throws {
        let rig = try HelperRig()
        let script = rig.folder.path("failing-installer.sh")
        try Data("#!/bin/bash\nexit 7\n".utf8).write(to: script)
        let installer = ToolInstaller(
            settings: rig.settings, timings: fastTimings, fetch: Downloads(file: script).fetch)

        await #expect(throws: ToolInstaller.Failure.failed) {
            try await installer.install(claude, from: claude.installer.value!)
        }
    }

    @Test("the download refuses an answer that is not 200 and one that ends on another host")
    func downloadChecksTheAnswer() async throws {
        let rig = try HelperRig()
        let into = try rig.folder.folder("downloads")
        let allowed = Installer(
            kind: .script(shell: "/bin/bash"), url: URL(string: "https://dl.example.test/install.sh")!,
            allowedHosts: ["dl.example.test"])

        let ok = HTTPSDownload(installer: allowed, session: StubURLProtocol.session(
            host: "dl.example.test", answer: .init(status: 200, body: Data("echo hi\n".utf8))))
        let file = try await ok.fetch(allowed.url, into: into)
        #expect(try String(contentsOf: file, encoding: .utf8) == "echo hi\n")

        let missing = HTTPSDownload(installer: allowed, session: StubURLProtocol.session(
            host: "dl.example.test", answer: .init(status: 404, body: Data())))
        await #expect(throws: ToolInstaller.Failure.unreachable) {
            _ = try await missing.fetch(allowed.url, into: into)
        }

        #expect(!HTTPSDownload.accepts(
            finalURL: URL(string: "https://elsewhere.example.test/install.sh")!, for: allowed))
        #expect(HTTPSDownload.accepts(finalURL: allowed.url, for: allowed))
    }

    @Test("an install_tool request installs the tool and reports it installed with its version")
    func installRequest() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        // The stand-in installer installs into $HOME/.local/bin; look only there.
        let bin = rig.home.appendingPathComponent(".local/bin")
        rig.settings.toolDir = bin.path
        let installer = ToolInstaller(
            settings: rig.settings, timings: fastTimings, fetch: Downloads(file: rig.tools.installer).fetch)

        let result = await installer.handle(helperRequest(.installTool, params: .init(provider: .claude)))

        #expect(result.outcome == .finished)
        #expect(result.checks == [HelperCheckResult(check: .toolInstalled, passed: true)])
        #expect(result.toolVersion == "0.0.1 (Claude Code stand-in)")
    }

    @Test("an install_tool request for a provider with no installer fails as not installed")
    func installRequestWithoutInstaller() async throws {
        let rig = try HelperRig(emptyToolDir: true)
        let downloads = Downloads(file: rig.tools.installer)
        let installer = ToolInstaller(settings: rig.settings, timings: fastTimings, fetch: downloads.fetch)

        let result = await installer.handle(helperRequest(.installTool, params: .init(provider: .grok)))

        #expect(result.outcome == .failed)
        #expect(result.checks == [HelperCheckResult(check: .toolInstalled, passed: false, failure: .notInstalled)])
        #expect(downloads.addresses.isEmpty)
    }
}
