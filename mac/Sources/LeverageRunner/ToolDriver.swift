import Foundation
import LeverageKit

/// What a tool run is for. It decides what the tool may do (CL-8): a build
/// may edit files in its folder, a review and the answering check may not.
enum ToolPurpose: String, Sendable, CaseIterable {
    /// The answering check of the add flow and of `LeverageRunner probe`.
    case check
    case build
    case review
}

/// The text a tool answered and the tokens its output gives (0 where it
/// gives none, CL-11).
struct ToolAnswer: Equatable, Sendable {
    let text: String
    let tokens: Int
}

/// How a tool run failed. Every failure is a release (CL-22); the tool's
/// own output is never kept or logged, only this.
enum ToolFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case couldNotStart(String)
    case exited(Int32)
    case signaled(Int32)
    case timedOut
    /// The output says the run failed (`is_error`, a status that is not
    /// `SUCCESS`, an `error` line, the signed-out text).
    case reportedError
    case unreadableOutput

    var description: String {
        switch self {
        case .couldNotStart(let reason): "the tool could not start (\(reason))"
        case .exited(let code): "the tool exited with code \(code)"
        case .signaled(let signal): "the tool ended on signal \(signal)"
        case .timedOut: "the tool ran past its time limit"
        case .reportedError: "the tool reported an error"
        case .unreadableOutput: "the tool's output could not be read"
        }
    }
}

/// Runs one prompt in a folder and returns the answer, or throws a
/// `ToolFailure`; cancelling the calling task ends the tool and everything
/// it started, and throws `CancellationError`.
protocol ToolDriver: Sendable {
    func run(prompt: String, in folder: URL, purpose: ToolPurpose) async throws -> ToolAnswer
}

/// What one run of a provider's tool is given.
struct ShapeInput: Sendable {
    let prompt: String
    let folder: String
    let purpose: ToolPurpose
    /// Nil for the check, which runs on the tool's defaults.
    let model: String?
    let effort: String?
    /// Where the tool writes its last message, for a tool that does.
    let outputFile: String?
    let timeoutSeconds: Int
}

/// One provider's arguments and output (PV-2). The four live in
/// ClaudeDriver.swift, CodexDriver.swift, AntigravityDriver.swift and
/// GrokDriver.swift.
protocol ProviderShape: Sendable {
    /// Whether the tool writes its answer to a file whose path it is given.
    var usesOutputFile: Bool { get }
    func arguments(_ input: ShapeInput) -> [String]
    /// The answer, from a run that exited 0 by itself.
    func read(standardOutput: Data, outputFile: Data?) throws -> ToolAnswer
}

enum ProviderShapes {
    static func shape(for provider: Provider) -> (any ProviderShape)? {
        switch provider {
        case .claude: ClaudeDriver()
        case .codex: CodexDriver()
        case .gemini: AntigravityDriver()
        case .grok: GrokDriver()
        default: nil
        }
    }

    /// The model and effort flags, each only when set.
    static func flags(model: (String, String?), effort: (String, String?)?) -> [String] {
        var flags: [String] = []
        if let value = model.1 { flags += [model.0, value] }
        if let effort, let value = effort.1 { flags += [effort.0, value] }
        return flags
    }

    /// A JSON object, or nil.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The whole-number value of a JSON field, or 0. Each form is asked
    /// for, since JSONSerialization on Linux may not hand back an NSNumber.
    static func count(_ value: Any?) -> Int {
        switch value {
        case let number as Int: number
        case let number as Double: Int(number)
        case let number as NSNumber: number.intValue
        default: 0
        }
    }

    /// The Boolean value of a JSON field, or nil.
    static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        default: nil
        }
    }
}

/// Runs a provider's tool as a child process: the allow-listed
/// environment, standard input closed, the work folder as its folder, the
/// time limit, and the whole process group ended on a stop (CL-10, CL-23).
struct ProcessToolDriver: ToolDriver {
    let tool: ToolConfiguration
    let shape: any ProviderShape

    init(tool: ToolConfiguration) throws {
        guard let shape = ProviderShapes.shape(for: tool.provider) else {
            throw RunnerConfigurationError.unsupportedProvider(tool.provider.rawValue)
        }
        self.tool = tool
        self.shape = shape
    }

    func run(prompt: String, in folder: URL, purpose: ToolPurpose) async throws -> ToolAnswer {
        // Codex writes its last message to a file of its own, kept outside the
        // work folder and removed after the run.
        var scratch: URL?
        if shape.usesOutputFile {
            let base = tool.parentEnvironment[EnvironmentKeys.tmpdir].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory
            let made = base.appendingPathComponent("leverage-run-\(UUID().uuidString.lowercased())")
            do {
                try FileManager.default.createDirectory(
                    at: made, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw ToolFailure.couldNotStart("no folder for the tool's answer")
            }
            scratch = made
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        let outputFile = scratch?.appendingPathComponent("last-message.txt")

        let seat = purpose != .check
        let input = ShapeInput(
            prompt: prompt, folder: folder.path, purpose: purpose,
            model: seat ? tool.model : nil, effort: seat ? tool.effort : nil,
            outputFile: outputFile?.path, timeoutSeconds: tool.timeoutSeconds)
        let request = SubprocessRequest(
            executable: tool.toolPath, arguments: shape.arguments(input), environment: tool.toolEnvironment,
            workingDirectory: folder.path, timeLimit: .seconds(tool.timeoutSeconds))

        let result: SubprocessResult
        do {
            result = try await Subprocess.run(request)
        } catch let error as SubprocessError {
            throw ToolFailure.couldNotStart(Self.reason(error))
        }
        if Task.isCancelled || result.endedBy == .stop { throw CancellationError() }
        if result.endedBy == .timeLimit { throw ToolFailure.timedOut }
        switch result.termination {
        case .signaled(let signal): throw ToolFailure.signaled(signal)
        case .exited(let code) where code != 0: throw ToolFailure.exited(code)
        case .exited: break
        }
        let written = outputFile.flatMap { try? Data(contentsOf: $0) }
        return try shape.read(standardOutput: result.standardOutput, outputFile: written)
    }

    private static func reason(_ error: SubprocessError) -> String {
        switch error {
        case .notAbsolute: "the path is not absolute"
        case .notExecutable: "the program is missing or cannot be run"
        case .startFailed(let call, let errno): "\(call) failed with \(errno)"
        }
    }
}
