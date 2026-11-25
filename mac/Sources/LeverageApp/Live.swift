import AppKit
import Foundation
import LeverageKit
#if canImport(LeverageAppServices)
import LeverageAppServices
#endif

/// What the app reads from its own bundle, as `scripts/build_app.sh`
/// assembles it (plan PK-1): the compose file in `Contents/Resources`, the
/// tag of the API image it built (a key of `Info.plist`), and the helper
/// and MCP programs next to the app's own program in `Contents/MacOS`.
struct LiveSettings: Equatable, Sendable {
    /// The `Info.plist` key build_app.sh writes the image tag under.
    static let imageTagKey = "LeverageAPIImageTag"
    /// compose.yaml's own default tag (`API_IMAGE_TAG:-local`), used outside
    /// a bundle or when the key holds something Docker would refuse.
    static let fallbackImageTag = "local"

    var composeSource: URL
    var imageTag: String
    var helperProgram: URL
    var mcpProgram: URL
    /// The bundle the app runs from; `UserNotifier.make` decides on it
    /// (HM-27). Outside a bundle it is the program's own folder.
    var bundleURL: URL

    init(info: [String: Any], resources: URL, executable: URL, bundleURL: URL? = nil) {
        self.bundleURL = bundleURL ?? executable.deletingLastPathComponent()
        composeSource = resources.appendingPathComponent("compose.yaml")
        if let tag = info[Self.imageTagKey] as? String, Self.isImageTag(tag) {
            imageTag = tag
        } else {
            imageTag = Self.fallbackImageTag
        }
        let programs = executable.deletingLastPathComponent()
        helperProgram = programs.appendingPathComponent("LeverageHelper")
        mcpProgram = programs.appendingPathComponent("LeverageMCP")
    }

    /// The running app's own bundle.
    static func bundled(_ bundle: Bundle = .main) -> LiveSettings {
        let executable = bundle.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "LeverageApp").absoluteURL
        return LiveSettings(
            info: bundle.infoDictionary ?? [:],
            resources: bundle.resourceURL ?? executable.deletingLastPathComponent(),
            executable: executable,
            bundleURL: bundle.bundleURL)
    }

    /// A Docker image tag: a letter, digit or underscore, then up to 127
    /// letters, digits, underscores, dots and dashes.
    static func isImageTag(_ tag: String) -> Bool {
        guard let first = tag.unicodeScalars.first, tag.unicodeScalars.count <= 128 else { return false }
        func allowed(_ scalar: Unicode.Scalar, extra: String) -> Bool {
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || extra.unicodeScalars.contains(scalar))
        }
        return allowed(first, extra: "_") && tag.unicodeScalars.dropFirst().allSatisfy { allowed($0, extra: "_.-") }
    }
}

enum LiveError: Error, Equatable {
    /// Another copy of the app runs on the same support folder (PK-8); its
    /// process id, when the lock file names one.
    case heldByAnotherCopy(processID: Int32?)
    /// The support folder's lock could not be taken; a line for the log.
    case unavailable(String)
}

/// Builds the services the app runs with: the real ones where
/// LeverageAppServices is built, `UnavailableRuntime` in the `app` build
/// lane, where it is not.
enum Live {
    #if canImport(LeverageAppServices)
    static let servicesAreBuilt = true
    #else
    static let servicesAreBuilt = false
    #endif

    /// The runtime for this launch. A second copy of the app on the same
    /// support folder brings the first one to the front and quits, before
    /// any window opens (PK-8).
    @MainActor
    static func runtime() -> any AppRuntime {
        // Before any call: what an earlier version's URL cache kept of the
        // app's calls, the owner's session included.
        LeftoverURLCache.remove()
        do {
            return try make(settings: .bundled(), environment: ProcessInfo.processInfo.environment)
        } catch LiveError.heldByAnotherCopy(let processID) {
            Log(component: "app").info("another copy of the app runs on this support folder; quitting")
            if let processID, let other = NSRunningApplication(processIdentifier: processID) {
                other.activate()
            }
            exit(0)
        } catch {
            // The window says the app could not start; the log says why.
            Log(component: "app").error("the app's services could not be made: \(error)")
            return UnavailableRuntime()
        }
    }

    /// Makes the runtime without starting anything: the server is started by
    /// the app model, the helper once the owner is signed in. It holds the
    /// support folder's lock for as long as it lives.
    static func make(
        settings: LiveSettings,
        environment: [String: String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> any AppRuntime {
        #if canImport(LeverageAppServices)
        let support = SupportFolder(environment: environment, home: home).url
        let lock: AppLock
        do {
            lock = try AppLock(supportFolder: support)
        } catch AppLockError.heldByAnotherCopy(let processID) {
            throw LiveError.heldByAnotherCopy(processID: processID)
        } catch {
            throw LiveError.unavailable("\(error)")
        }
        let server = ServerSupervisor(configuration: .init(
            supportFolder: support,
            dockerFolders: DockerLocator.applicationFolders(home: home),
            home: home,
            composeSource: settings.composeSource,
            imageTag: settings.imageTag,
            composeProject: ServerSupervisor.Configuration.composeProject(environment: environment),
            mcpProgram: settings.mcpProgram))
        let helper = HelperSupervisor(configuration: .init(
            helperProgram: settings.helperProgram, supportFolder: support, environment: environment))
        return LiveRuntime(
            server: server, helper: helper, sessions: SessionStores.make(environment: environment),
            notifier: UserNotifier.make(bundleURL: settings.bundleURL, environment: environment),
            inboxCursor: InboxCursorStore(folder: support), setupProgress: SetupProgressStore(folder: support),
            lock: lock)
        #else
        return UnavailableRuntime()
        #endif
    }
}

#if canImport(LeverageAppServices)
/// The real services, and the support folder's lock, which is released when
/// the runtime is gone (the app keeps it for its whole life). The notifier
/// is the real one only in an app bundle (HM-27); the inbox cursor is a file
/// in the support folder, so it outlives the app (HM-29), and so is the
/// owner's setup choice.
private struct LiveRuntime: AppRuntime {
    let server: any ServerSupervising
    let helper: any HelperSupervising
    let sessions: any SessionStoring
    let notifier: any Notifying
    let inboxCursor: any InboxCursorStoring
    let setupProgress: any SetupProgressStoring
    let lock: AppLock
}
#endif
