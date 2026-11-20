import Foundation
import LeverageKit

/// Why the runner will not start. Each names the variable or value at
/// fault, never a value that could be a secret.
enum RunnerConfigurationError: Error, Equatable, CustomStringConvertible {
    /// A variable that must be set is missing or empty.
    case missing(String)
    case notAbsolute(String)
    /// The seat's role is one this milestone does not run (planner and
    /// orchestrator arrive with jobs, milestone 4).
    case unsupportedRole(String)
    /// Not one of the four logins.
    case unsupportedProvider(String)
    /// Claude or Codex with no account folder of leverage's own, and the
    /// developer switch not set (PV-6).
    case noAccountFolder(Provider)
    case accountFolderMissing(String)
    case invalidTimeout(String)
    /// The provider is not run in this role: agy's plan mode did not answer a
    /// plain prompt in WP11's step 0, so it cannot review (CL-8).
    case reviewerNotOffered(Provider)
    /// The variable does not hold an id.
    case notAnIdentifier(String)
    /// Both a task and a review to continue.
    case twoWorksToContinue
    /// Work the seat's role does not do: a task for a reviewer, a review
    /// for a builder.
    case workNotForRole(String)

    var description: String {
        switch self {
        case .missing(let name): "\(name) is not set"
        case .notAbsolute(let name): "\(name) is not an absolute path"
        case .unsupportedRole(let role): "the role \(role) is not run by this runner"
        case .unsupportedProvider(let provider): "\(provider) is not a login this runner drives"
        case .noAccountFolder(let provider):
            "\(provider.rawValue) needs the account folder leverage made (\(EnvironmentKeys.settingsDir))"
        case .accountFolderMissing(let path): "the account folder \(path) does not exist"
        case .invalidTimeout(let value): "\(EnvironmentKeys.toolTimeoutSeconds) is not a positive number: \(value)"
        case .reviewerNotOffered(let provider): "\(provider.rawValue) is not offered as a reviewer yet"
        case .notAnIdentifier(let name): "\(name) is not an id"
        case .twoWorksToContinue:
            "\(EnvironmentKeys.continueTaskID) and \(EnvironmentKeys.continueReviewID) are both set"
        case .workNotForRole(let name): "\(name) is not work for this seat's role"
        }
    }
}

/// What a tool run needs: the provider's tool, its account and its limits.
/// The probe needs only this; a seat's run needs `RunnerConfiguration`.
struct ToolConfiguration: Sendable, Equatable {
    /// A seat's tool run (plan §2.4).
    static let defaultTimeoutSeconds = 1800
    /// The probe's one test prompt: the inventory's probes took 6 to 7
    /// seconds and ran under a 120-second limit.
    static let probeTimeoutSeconds = 120

    let provider: Provider
    let entry: ProviderEntry
    let toolPath: String
    /// The account's settings folder; nil for a provider with one sign-in
    /// for the Mac, and under the developer switch (PV-6).
    let accountFolder: String?
    let model: String?
    let effort: String?
    let timeoutSeconds: Int
    let supportFolder: String
    let toolDir: String?
    /// The runner's own environment without any leverage variable: what
    /// the tool's allow-list takes `HOME`, `TMPDIR`, `LANG` and `USER` from.
    let parentEnvironment: [String: String]

    init(environment: [String: String], defaultTimeout: Int = ToolConfiguration.defaultTimeoutSeconds) throws {
        func value(_ name: String) -> String? {
            environment[name].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }

        guard let providerName = value(EnvironmentKeys.provider) else {
            throw RunnerConfigurationError.missing(EnvironmentKeys.provider)
        }
        guard let provider = Provider(rawValue: providerName), provider.facts.kind == .login,
              let entry = ProviderCatalog.entry(for: provider.rawValue) else {
            throw RunnerConfigurationError.unsupportedProvider(providerName)
        }
        guard let toolPath = value(EnvironmentKeys.toolPath) else {
            throw RunnerConfigurationError.missing(EnvironmentKeys.toolPath)
        }
        guard toolPath.hasPrefix("/") else { throw RunnerConfigurationError.notAbsolute(EnvironmentKeys.toolPath) }

        var accountFolder: String?
        if entry.accountFolderVariable.value != nil {
            if let folder = value(EnvironmentKeys.settingsDir) {
                var isFolder: ObjCBool = false
                guard folder.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue
                else { throw RunnerConfigurationError.accountFolderMissing(folder) }
                accountFolder = folder
            } else if environment[EnvironmentKeys.devToolLogin] != "1" {
                throw RunnerConfigurationError.noAccountFolder(provider)
            }
        }

        var timeout = defaultTimeout
        if let text = value(EnvironmentKeys.toolTimeoutSeconds) {
            guard let seconds = Int(text), seconds > 0 else { throw RunnerConfigurationError.invalidTimeout(text) }
            timeout = seconds
        }

        let home = environment[EnvironmentKeys.home] ?? NSHomeDirectory()
        self.provider = provider
        self.entry = entry
        self.toolPath = toolPath
        self.accountFolder = accountFolder
        model = value(EnvironmentKeys.model)
        effort = value(EnvironmentKeys.effort)
        timeoutSeconds = timeout
        supportFolder = value(EnvironmentKeys.supportDir) ?? "\(home)/Library/Application Support/leverage"
        toolDir = value(EnvironmentKeys.toolDir)
        parentEnvironment = environment.filter { !$0.key.hasPrefix("LEVERAGE_") }
    }

    /// The tool's whole environment (CL-10), from the one home of it.
    var toolEnvironment: [String: String] {
        ProviderCatalog.toolEnvironment(
            for: entry, from: parentEnvironment,
            toolFolder: (toolPath as NSString).deletingLastPathComponent,
            accountFolder: accountFolder, supportFolder: supportFolder, toolDir: toolDir)
    }

    var home: String { parentEnvironment[EnvironmentKeys.home] ?? NSHomeDirectory() }
}

/// A seat's run, from the environment the helper's launcher gives it
/// (plan §2.4). It fails closed: no seat token, no run.
struct RunnerConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let apiBaseURL: URL
    let seatToken: String
    let role: SeatRole
    let tool: ToolConfiguration
    /// Where a task with no work reference gets its folder (CL-7).
    let workRoot: URL
    /// The credential the run is on; nil for a seat that connects on its
    /// own, whose runs detect nothing (HM-19).
    let credentialID: UUID?
    /// The work the run is started to continue (HD-9).
    let continuing: WorkToContinue?

    init(environment: [String: String]) throws {
        guard let token = environment[EnvironmentKeys.seatToken], !token.isEmpty else {
            throw RunnerConfigurationError.missing(EnvironmentKeys.seatToken)
        }
        guard let roleName = environment[EnvironmentKeys.seatRole], !roleName.isEmpty else {
            throw RunnerConfigurationError.missing(EnvironmentKeys.seatRole)
        }
        guard let role = SeatRole(rawValue: roleName), role == .builder || role == .reviewer else {
            throw RunnerConfigurationError.unsupportedRole(roleName)
        }
        let tool = try ToolConfiguration(environment: environment)
        if role == .reviewer, !Self.reviews(tool.provider) {
            throw RunnerConfigurationError.reviewerNotOffered(tool.provider)
        }

        apiBaseURL = Configuration(environment: environment).apiBaseURL
        seatToken = token
        self.role = role
        self.tool = tool
        if let root = environment[EnvironmentKeys.workRoot], !root.isEmpty {
            workRoot = URL(fileURLWithPath: root, isDirectory: true)
        } else {
            workRoot = URL(fileURLWithPath: tool.supportFolder, isDirectory: true)
                .appendingPathComponent("work", isDirectory: true)
        }
        credentialID = try Self.identifier(EnvironmentKeys.credentialID, in: environment)
        let task = try Self.identifier(EnvironmentKeys.continueTaskID, in: environment)
        let review = try Self.identifier(EnvironmentKeys.continueReviewID, in: environment)
        switch (task, review) {
        case (nil, nil):
            continuing = nil
        case (let task?, nil):
            guard role == .builder else { throw RunnerConfigurationError.workNotForRole(EnvironmentKeys.continueTaskID) }
            continuing = .task(task)
        case (nil, let review?):
            guard role == .reviewer else {
                throw RunnerConfigurationError.workNotForRole(EnvironmentKeys.continueReviewID)
            }
            continuing = .review(review)
        case (_?, _?):
            throw RunnerConfigurationError.twoWorksToContinue
        }
    }

    /// The id a variable holds; nil when it is absent or empty.
    private static func identifier(_ name: String, in environment: [String: String]) throws -> UUID? {
        guard let text = environment[name]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let id = UUID(uuidString: text) else { throw RunnerConfigurationError.notAnIdentifier(name) }
        return id
    }

    /// Whether a provider's read-only mode answers a plain prompt, so that it
    /// can review (CL-8). Gemini's `--mode plan` answered the "ready" prompt
    /// with a plan to approve (WP11's step 0, 2026-11-19), so it does not.
    /// Grok's plan mode has never run (not signed in on this Mac).
    static func reviews(_ provider: Provider) -> Bool {
        provider != .gemini
    }

    var description: String {
        "RunnerConfiguration(api: \(apiBaseURL.absoluteString), role: \(role.rawValue), "
            + "provider: \(tool.provider.rawValue), credential: \(credentialID?.contractString ?? "none"), "
            + "continuing: \(continuing.map(Self.describe) ?? "nothing"), seat token: [removed])"
    }

    private static func describe(_ work: WorkToContinue) -> String {
        switch work {
        case .task(let id): "task \(id.contractString)"
        case .review(let id): "review \(id.contractString)"
        }
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}
