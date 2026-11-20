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

/// How a tool run failed. A failure is a release (CL-22) unless
/// `Interruption` reads the run as a limit or a sign-out (HD-5); the tool's
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

/// How one tool run ended: the answer, or the failure with the run's record
/// when the tool ran at all. The record goes to `Interruption` and to
/// nobody else (plan §2.2): it is never logged, kept or sent.
enum ToolRun: Equatable, Sendable {
    case answered(ToolAnswer)
    /// The record is nil when the tool did not start.
    case failed(ToolFailure, ToolRunRecord?)
}

/// One tool run: the prompt, the folder, what it is for, and the limits a
/// caller may set on it (milestone 4 plan section 2.2, RD-34).
struct ToolRunRequest: Equatable, Sendable {
    let prompt: String
    let folder: URL
    let purpose: ToolPurpose
    /// The run's own time limit in whole seconds: a job's ends 10 seconds
    /// before its `run_due_at`. It never lengthens the configuration's
    /// limit; nil is the configuration's.
    let timeLimitSeconds: Int?
    /// Whether the seat's model and effort are passed. A build and a review
    /// pass them; the probe's answering check never does; a job's check run
    /// does, so that the model the owner chose judges (RV-5).
    let seatModel: Bool

    init(prompt: String, folder: URL, purpose: ToolPurpose, timeLimitSeconds: Int? = nil, seatModel: Bool? = nil) {
        self.prompt = prompt
        self.folder = folder
        self.purpose = purpose
        self.timeLimitSeconds = timeLimitSeconds
        self.seatModel = seatModel ?? (purpose != .check)
    }
}

/// Runs one prompt in a folder. `execute` gives the answer or the failure
/// with its record; cancelling the calling task ends the tool and
/// everything it started, and throws `CancellationError`, the one error it
/// throws.
protocol ToolDriver: Sendable {
    func execute(_ request: ToolRunRequest) async throws -> ToolRun
}

extension ToolDriver {
    /// A run with the configuration's limit, and the seat's model unless it
    /// is the answering check (milestone 2's form).
    func execute(prompt: String, in folder: URL, purpose: ToolPurpose) async throws -> ToolRun {
        try await execute(ToolRunRequest(prompt: prompt, folder: folder, purpose: purpose))
    }

    /// The answer, or the failure thrown as a `ToolFailure` (the probe's
    /// and milestone 2's form).
    func run(prompt: String, in folder: URL, purpose: ToolPurpose) async throws -> ToolAnswer {
        switch try await execute(prompt: prompt, in: folder, purpose: purpose) {
        case .answered(let answer): return answer
        case .failed(let failure, _): throw failure
        }
    }
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

    func execute(_ request: ToolRunRequest) async throws -> ToolRun {
        let prompt = request.prompt, folder = request.folder, purpose = request.purpose
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
                return .failed(.couldNotStart("no folder for the tool's answer"), nil)
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
            return .failed(.couldNotStart(Self.reason(error)), nil)
        }
        if Task.isCancelled || result.endedBy == .stop { throw CancellationError() }
        let record = ToolRunRecord(result)
        if result.endedBy == .timeLimit { return .failed(.timedOut, record) }
        switch result.termination {
        case .signaled(let signal): return .failed(.signaled(signal), record)
        case .exited(let code) where code != 0: return .failed(.exited(code), record)
        case .exited: break
        }
        let written = outputFile.flatMap { try? Data(contentsOf: $0) }
        do {
            return .answered(try shape.read(standardOutput: result.standardOutput, outputFile: written))
        } catch let failure as ToolFailure {
            return .failed(failure, record)
        }
    }

    private static func reason(_ error: SubprocessError) -> String {
        switch error {
        case .notAbsolute: "the path is not absolute"
        case .notExecutable: "the program is missing or cannot be run"
        case .startFailed(let call, let errno): "\(call) failed with \(errno)"
        }
    }
}
