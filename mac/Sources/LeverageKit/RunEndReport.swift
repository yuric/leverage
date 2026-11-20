import Foundation

/// The one line a runner prints on standard output when its account stops
/// (plan HD-6), before it exits with code 5. The helper reads it and sends
/// `report_limit` or `report_signed_out`. It holds the kind, the window, the
/// reset time, the task, review or job id, the tool's version and the time
/// observed; never a word of the tool's reply. Nothing of it is written to
/// disk.
///
/// The line is strict: every key is present (null where there is no value),
/// and a line with a key it does not know, a missing key, another version, a
/// window on a sign-out or none on a limit, or more than one of a task, a
/// review and a job, is refused. The helper treats a refused line as no line (HD-6: code 4).
public struct RunEndReport: Codable, Equatable, Sendable {
    /// The version of this line's shape.
    public static let formatVersion = 1

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case limit
        case signedOut = "signed_out"
    }

    public let version: Int
    public let kind: Kind
    /// Set for a limit, nil for a sign-out.
    public let window: LimitWindow?
    /// The reset time the reply stated; nil when it stated none, and for a
    /// sign-out.
    public let resetAt: Date?
    /// The task the run was building, if any.
    public let taskID: UUID?
    /// The review the run was doing, if any.
    public let reviewID: UUID?
    /// The job the run was doing, if any.
    public let jobID: UUID?
    /// The provider tool's version, as its `--version` printed it.
    public let toolVersion: String?
    /// When the runner saw the run end.
    public let observedAt: Date

    public init(
        kind: Kind, window: LimitWindow?, resetAt: Date?, taskID: UUID?, reviewID: UUID?, jobID: UUID? = nil,
        toolVersion: String?, observedAt: Date
    ) {
        self.version = Self.formatVersion
        self.kind = kind
        self.window = window
        self.resetAt = resetAt
        self.taskID = taskID
        self.reviewID = reviewID
        self.jobID = jobID
        self.toolVersion = toolVersion
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, kind, window
        case resetAt = "reset_at"
        case taskID = "task_id"
        case reviewID = "review_id"
        case jobID = "job_id"
        case toolVersion = "tool_version"
        case observedAt = "observed_at"
    }

    /// Any key, to find the ones the line should not have.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let every = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = every.allKeys.map(\.stringValue).sorted().first(where: { !known.contains($0) }) {
            throw RunEndReportError.unknownKey(unknown)
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `decode` of an optional still requires the key: a missing key is
        // refused, a null is read as nil.
        version = try container.decode(Int.self, forKey: .version)
        kind = try container.decode(Kind.self, forKey: .kind)
        window = try container.decode(LimitWindow?.self, forKey: .window)
        resetAt = try container.decode(Date?.self, forKey: .resetAt)
        taskID = try container.decode(UUID?.self, forKey: .taskID)
        reviewID = try container.decode(UUID?.self, forKey: .reviewID)
        jobID = try container.decode(UUID?.self, forKey: .jobID)
        toolVersion = try container.decode(String?.self, forKey: .toolVersion)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        try container.encode(window, forKey: .window)
        try container.encode(resetAt, forKey: .resetAt)
        try container.encodeID(taskID, forKey: .taskID)
        try container.encodeID(reviewID, forKey: .reviewID)
        try container.encodeID(jobID, forKey: .jobID)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encode(observedAt, forKey: .observedAt)
    }

    private func validate() throws {
        guard version == Self.formatVersion else {
            throw RunEndReportError.invalid("version \(version) is not \(Self.formatVersion)")
        }
        switch kind {
        case .limit:
            guard window != nil else { throw RunEndReportError.invalid("a limit names its window") }
        case .signedOut:
            guard window == nil, resetAt == nil else {
                throw RunEndReportError.invalid("a sign-out has no window and no reset time")
            }
        }
        guard [taskID, reviewID, jobID].compactMap({ $0 }).count <= 1 else {
            throw RunEndReportError.invalid("a report names a task, a review or a job, not more than one")
        }
    }

    /// The report as one line of JSON, with no newline.
    public func line() throws -> String {
        String(decoding: try LeverageJSON.encoder().encode(self), as: UTF8.self)
    }

    /// Reads one line.
    public init(line: String) throws {
        guard !line.contains(where: \.isNewline) else { throw RunEndReportError.notOneLine }
        self = try LeverageJSON.decoder().decode(RunEndReport.self, from: Data(line.utf8))
    }

    /// Reads the last line that is not blank of a runner's standard output.
    public init(lastLineOf output: Data) throws {
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { throw RunEndReportError.notOneLine }
        try self.init(line: last)
    }
}

/// Why a line is not a `RunEndReport`. It names a key or a rule, never the
/// line's text.
public enum RunEndReportError: Error, Equatable, Sendable {
    case notOneLine
    case unknownKey(String)
    case invalid(String)
}
