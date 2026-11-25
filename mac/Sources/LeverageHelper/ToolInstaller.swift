import Foundation
import LeverageKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Installs a provider's tool from its catalog source, after the owner
/// confirmed what and from where (L603, L715, PV-5), with no terminal and no
/// administrator: a vendor's script run with its shell, or a vendor's
/// release archive unpacked into `<support folder>/tools/<provider>/`, where
/// `ToolLocator` looks first. An address that is not HTTPS on a host the
/// catalog entry lists is refused before anything is fetched.
///
/// The download is a parameter, so no test fetches or runs a real
/// installer.
struct ToolInstaller: Sendable {
    enum Failure: Error, Equatable {
        /// The address is not HTTPS on a listed host.
        case refusedAddress
        /// The download did not answer with the file.
        case unreachable
        /// The script or the unpacking failed.
        case failed
        /// The script did not finish within the install limit.
        case timedOut
    }

    /// Fetches `address` into the folder given and returns the local file.
    typealias Fetch = @Sendable (_ address: URL, _ folder: URL) async throws -> URL

    let settings: HelperSettings
    let timings: HelperTimings
    /// Nil: the real download over HTTPS.
    let fetch: Fetch?

    init(settings: HelperSettings, timings: HelperTimings, fetch: Fetch? = nil) {
        self.settings = settings
        self.timings = timings
        self.fetch = fetch
    }

    func install(_ entry: ProviderEntry, from installer: Installer) async throws {
        guard installer.permits(installer.url) else { throw Failure.refusedAddress }
        let files = FileManager.default
        let downloads = settings.supportFolder.appendingPathComponent(
            "downloads/\(UUID().uuidString.lowercased())", isDirectory: true)
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: downloads) }

        let file: URL
        do {
            if let fetch {
                file = try await fetch(installer.url, downloads)
            } else {
                file = try await HTTPSDownload(installer: installer).fetch(installer.url, into: downloads)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable
        }

        switch installer.kind {
        case .script(let shell):
            try await run(scriptRequest(shell: shell, script: file))
        case .archive(let program):
            try await unpack(file, program: program, entry: entry)
        }
    }

    /// The installer script's run: its shell, an allow-listed environment
    /// (no Leverage token), standard input closed, and the install limit.
    func scriptRequest(shell: String, script: URL) -> SubprocessRequest {
        SubprocessRequest(
            executable: shell, arguments: [script.path],
            environment: Subprocess.environment(
                allowing: [EnvironmentKeys.home, EnvironmentKeys.tmpdir, EnvironmentKeys.lang, EnvironmentKeys.user],
                from: settings.environment,
                setting: [EnvironmentKeys.path: "/usr/bin:/bin:/usr/sbin:/sbin"]),
            timeLimit: timings.installLimit, gracePeriod: .seconds(5), maximumOutputBytes: 1 << 20)
    }

    private func run(_ request: SubprocessRequest) async throws {
        let result: SubprocessResult
        do {
            result = try await Subprocess.run(request)
        } catch {
            throw Failure.failed
        }
        if result.endedBy == .timeLimit { throw Failure.timedOut }
        guard result.succeeded else { throw Failure.failed }
    }

    /// Unpacks the archive into the provider's tools folder and names its
    /// program after the tool.
    private func unpack(_ archive: URL, program: String, entry: ProviderEntry) async throws {
        let files = FileManager.default
        let folder = settings.supportFolder.appendingPathComponent("tools/\(entry.id)", isDirectory: true)
        let staging = folder.deletingLastPathComponent()
            .appendingPathComponent(".unpack-\(UUID().uuidString.lowercased())", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        // tar refuses members that leave the folder (absolute paths, "..").
        try await run(SubprocessRequest(
            executable: "/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", staging.path],
            environment: ["PATH": "/usr/bin:/bin"], timeLimit: timings.installLimit, maximumOutputBytes: 1 << 20))

        let unpacked = staging.appendingPathComponent(program)
        var isFolder: ObjCBool = false
        guard !program.contains(".."), files.fileExists(atPath: unpacked.path, isDirectory: &isFolder),
              !isFolder.boolValue
        else { throw Failure.failed }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent(entry.toolName)
        try? files.removeItem(at: tool)
        do {
            try files.moveItem(at: unpacked, to: tool)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        } catch {
            throw Failure.failed
        }
    }

    /// An `install_tool` request (IN-23): installs the provider's tool and
    /// reports it installed with its version, or the reason it is not.
    func handle(_ request: HelperRequest) async -> HelperRequestResult {
        func failed(_ failure: HelperCheckFailure) -> HelperRequestResult {
            HelperRequestResult(
                outcome: .failed, checks: [HelperCheckResult(check: .toolInstalled, passed: false, failure: failure)],
                toolVersion: nil)
        }
        guard let provider = request.params.provider, let entry = ProviderCatalog.entry(for: provider.rawValue),
              let installer = entry.installer.value
        else { return failed(.notInstalled) }
        do {
            try await install(entry, from: installer)
        } catch let failure as Failure {
            switch failure {
            case .refusedAddress: return failed(.rejected)
            case .unreachable: return failed(.unreachable)
            case .failed: return failed(.notInstalled)
            case .timedOut: return failed(.timedOut)
            }
        } catch {
            return failed(.notInstalled)
        }
        guard let tool = await ToolLocator(settings: settings, timings: timings).locate(entry) else {
            return failed(.notInstalled)
        }
        return HelperRequestResult(
            outcome: .finished, checks: [HelperCheckResult(check: .toolInstalled, passed: true)],
            toolVersion: tool.version)
    }
}

/// The real download: HTTPS only, and the answer must be a 200 from an
/// address the installer permits, also after a redirect. It uses the
/// session that keeps nothing, as the API's clients do, so that no program
/// of Leverage's has a URL cache on disk.
struct HTTPSDownload: Sendable {
    let installer: Installer
    let session: URLSession

    init(installer: Installer, session: URLSession = HTTPTransport.uncachedSession) {
        self.installer = installer
        self.session = session
    }

    static func accepts(finalURL: URL, for installer: Installer) -> Bool {
        installer.permits(finalURL)
    }

    func fetch(_ address: URL, into folder: URL) async throws -> URL {
        guard installer.permits(address) else { throw ToolInstaller.Failure.refusedAddress }
        var request = URLRequest(url: address)
        request.timeoutInterval = 120
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: error ?? ToolInstaller.Failure.unreachable)
                }
            }
            task.resume()
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, Self.accepts(finalURL: final, for: installer)
        else { throw ToolInstaller.Failure.unreachable }
        let file = folder.appendingPathComponent(address.lastPathComponent.isEmpty ? "download" : address.lastPathComponent)
        try data.write(to: file)
        return file
    }
}
