import Foundation

/// `HelperRequestParams`: the non-secret inputs a request carries (IN-22).
/// Which fields are set depends on the request's kind.
public struct HelperRequestParams: Codable, Equatable, Sendable {
    public let provider: Provider?
    public let credentialKind: CredentialKind?
    public let role: SeatRole?
    /// The seat's model; nil for the tool's default.
    public let model: String?
    /// The seat's effort; nil for the tool's default.
    public let effort: String?
    /// A start request's task to continue; at most one of `taskID` and
    /// `reviewID` is set (HD-1, HD-9).
    public let taskID: UUID?
    /// A start request's review to continue.
    public let reviewID: UUID?

    public init(
        provider: Provider? = nil, credentialKind: CredentialKind? = nil, role: SeatRole? = nil,
        model: String? = nil, effort: String? = nil, taskID: UUID? = nil, reviewID: UUID? = nil
    ) {
        self.provider = provider
        self.credentialKind = credentialKind
        self.role = role
        self.model = model
        self.effort = effort
        self.taskID = taskID
        self.reviewID = reviewID
    }

    enum CodingKeys: String, CodingKey {
        case provider, role, model, effort
        case taskID = "task_id"
        case reviewID = "review_id"
        case credentialKind = "credential_kind"
    }
}

/// `InstallOffer`: what would be installed for a missing tool, and from
/// where, or that leverage cannot install it (PV-5).
public struct InstallOffer: Codable, Equatable, Sendable {
    public let installable: Bool
    public let what: String?
    public let sourceURL: URL?

    public init(installable: Bool, what: String?, sourceURL: URL?) {
        self.installable = installable
        self.what = what
        self.sourceURL = sourceURL
    }

    enum CodingKeys: String, CodingKey {
        case installable, what
        case sourceURL = "source_url"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(installable, forKey: .installable)
        try container.encode(what, forKey: .what)
        try container.encode(sourceURL?.absoluteString, forKey: .sourceURL)
    }
}

/// `HelperCheckProgress`: one check's state while a request runs; what the
/// helper reports through `report_request_progress` (IN-23).
public struct HelperCheckProgress: Codable, Equatable, Sendable {
    public let check: HelperCheck
    public let state: HelperCheckState
    public let failure: HelperCheckFailure?
    public let install: InstallOffer?

    public init(check: HelperCheck, state: HelperCheckState, failure: HelperCheckFailure? = nil,
                install: InstallOffer? = nil) {
        self.check = check
        self.state = state
        self.failure = failure
        self.install = install
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(check, forKey: .check)
        try container.encode(state, forKey: .state)
        try container.encode(failure, forKey: .failure)
        try container.encode(install, forKey: .install)
    }

    enum CodingKeys: String, CodingKey {
        case check, state, failure, install
    }
}

/// `HelperCheckResult`: one check's end.
public struct HelperCheckResult: Codable, Equatable, Sendable {
    public let check: HelperCheck
    public let passed: Bool
    public let failure: HelperCheckFailure?

    public init(check: HelperCheck, passed: Bool, failure: HelperCheckFailure? = nil) {
        self.check = check
        self.passed = passed
        self.failure = failure
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(check, forKey: .check)
        try container.encode(passed, forKey: .passed)
        try container.encode(failure, forKey: .failure)
    }

    enum CodingKeys: String, CodingKey {
        case check, passed, failure
    }
}

/// `HelperRequestResult`: how a request ended; what the helper reports
/// through `report_request_result`. `plan` and `accountEmail` go to the
/// credential's row only (IN-25).
public struct HelperRequestResult: Codable, Equatable, Sendable {
    public let outcome: HelperRequestOutcome
    public let checks: [HelperCheckResult]
    public let toolVersion: String?
    public let plan: String?
    public let accountEmail: String?

    public init(
        outcome: HelperRequestOutcome, checks: [HelperCheckResult], toolVersion: String?, plan: String? = nil,
        accountEmail: String? = nil
    ) {
        self.outcome = outcome
        self.checks = checks
        self.toolVersion = toolVersion
        self.plan = plan
        self.accountEmail = accountEmail
    }

    enum CodingKeys: String, CodingKey {
        case outcome, checks, plan
        case toolVersion = "tool_version"
        case accountEmail = "account_email"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(checks, forKey: .checks)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encode(plan, forKey: .plan)
        try container.encode(accountEmail, forKey: .accountEmail)
    }
}

/// `HelperRequest`: one request to the helper.
public struct HelperRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: HelperRequestKind
    public let seatID: UUID?
    public let credentialID: UUID?
    public let state: HelperRequestState
    public let requestedAt: Date
    public let pickedUpAt: Date?
    public let finishedAt: Date?
    public let result: HelperRequestResult?
    public let params: HelperRequestParams
    public let progress: [HelperCheckProgress]
    /// Changes with every report; give it back as `changedAfter`.
    public let updatedAt: Date

    public init(
        id: UUID, kind: HelperRequestKind, seatID: UUID? = nil, credentialID: UUID? = nil,
        state: HelperRequestState, requestedAt: Date, pickedUpAt: Date? = nil, finishedAt: Date? = nil,
        result: HelperRequestResult? = nil, params: HelperRequestParams = HelperRequestParams(),
        progress: [HelperCheckProgress] = [], updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.seatID = seatID
        self.credentialID = credentialID
        self.state = state
        self.requestedAt = requestedAt
        self.pickedUpAt = pickedUpAt
        self.finishedAt = finishedAt
        self.result = result
        self.params = params
        self.progress = progress
        self.updatedAt = updatedAt ?? requestedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, state, result, params, progress
        case seatID = "seat_id"
        case credentialID = "credential_id"
        case requestedAt = "requested_at"
        case pickedUpAt = "picked_up_at"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
    }
}

/// `HelperRequestStatus`: `GET /v1/owner/helper-requests/{id}`.
public struct HelperRequestStatus: Codable, Equatable, Sendable {
    public let request: HelperRequest
    public let asOfSeq: Int

    public init(request: HelperRequest, asOfSeq: Int) {
        self.request = request
        self.asOfSeq = asOfSeq
    }

    enum CodingKeys: String, CodingKey {
        case request
        case asOfSeq = "as_of_seq"
    }
}

/// `HelperNext`: `GET /v1/helper/next`; nil when there is nothing to do.
public struct HelperNext: Codable, Equatable, Sendable {
    public let request: HelperRequest?

    public init(request: HelperRequest?) {
        self.request = request
    }
}
