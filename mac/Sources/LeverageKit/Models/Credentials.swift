import Foundation

/// `Credential`: a login or an API token, named by its id everywhere but
/// its own row.
public struct Credential: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: CredentialKind
    public let provider: Provider
    public let name: String
    public let maskedLabel: String?
    public let plan: String?
    public let accountEmail: String?
    public let state: CredentialState
    public let limitedUntil: Date?
    public let position: Int
    public let model: String?
    public let effort: String?
    public let strengthRank: Int?
    public let lastVerifiedAt: Date?
    /// When a limit was reported for it; nil when it is not limited.
    /// `limitedUntil` is when that limit ends, nil when the provider gave no
    /// time. Limited means this is set and `limitedUntil` is nil or later
    /// than now (HE-3).
    public let limitedSince: Date?

    public init(
        id: UUID, kind: CredentialKind = .login, provider: Provider, name: String, maskedLabel: String? = nil,
        plan: String? = nil, accountEmail: String? = nil, state: CredentialState = .active,
        limitedUntil: Date? = nil, limitedSince: Date? = nil, position: Int, model: String? = nil,
        effort: String? = nil, strengthRank: Int? = nil, lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.name = name
        self.maskedLabel = maskedLabel
        self.plan = plan
        self.accountEmail = accountEmail
        self.state = state
        self.limitedUntil = limitedUntil
        self.limitedSince = limitedSince
        self.position = position
        self.model = model
        self.effort = effort
        self.strengthRank = strengthRank
        self.lastVerifiedAt = lastVerifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, provider, name, plan, state, position, model, effort
        case maskedLabel = "masked_label"
        case accountEmail = "account_email"
        case limitedUntil = "limited_until"
        case limitedSince = "limited_since"
        case strengthRank = "strength_rank"
        case lastVerifiedAt = "last_verified_at"
    }
}

/// `Figure`: one figure of a usage reading.
public struct Figure: Codable, Equatable, Sendable {
    public let label: String
    public let kind: FigureKind
    public let window: LimitWindow?
    public let percentUsed: Double?
    public let resetAt: Date?
    /// A number, a string, or nil.
    public let value: JSONValue?

    public init(
        label: String, kind: FigureKind, window: LimitWindow?, percentUsed: Double?, resetAt: Date?,
        value: JSONValue?
    ) {
        self.label = label
        self.kind = kind
        self.window = window
        self.percentUsed = percentUsed
        self.resetAt = resetAt
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case label, kind, window, value
        case percentUsed = "percent_used"
        case resetAt = "reset_at"
    }
}

/// `Reset`: a reset a reading reports.
public struct Reset: Codable, Equatable, Sendable {
    public let count: Int
    public let kind: ResetKind
    public let expiresAt: Date?

    public init(count: Int, kind: ResetKind, expiresAt: Date?) {
        self.count = count
        self.kind = kind
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case count, kind
        case expiresAt = "expires_at"
    }
}

/// `CredentialReading`: the latest usage reading of a credential.
public struct CredentialReading: Codable, Equatable, Sendable {
    public let credentialID: UUID
    public let observedAt: Date
    public let state: ReadingState
    public let toolVersion: String?
    public let figures: [Figure]
    public let resets: [Reset]?

    public init(
        credentialID: UUID, observedAt: Date, state: ReadingState, toolVersion: String?, figures: [Figure],
        resets: [Reset]?
    ) {
        self.credentialID = credentialID
        self.observedAt = observedAt
        self.state = state
        self.toolVersion = toolVersion
        self.figures = figures
        self.resets = resets
    }

    enum CodingKeys: String, CodingKey {
        case state, figures, resets
        case credentialID = "credential_id"
        case observedAt = "observed_at"
        case toolVersion = "tool_version"
    }
}

/// `CredentialWithReading`: a row of the Credentials list.
public struct CredentialWithReading: Codable, Equatable, Sendable {
    public let credential: Credential
    public let reading: CredentialReading?

    public init(credential: Credential, reading: CredentialReading? = nil) {
        self.credential = credential
        self.reading = reading
    }
}

/// `CredentialsList`: `GET /v1/owner/credentials`.
public struct CredentialsList: Codable, Equatable, Sendable {
    public let credentials: [CredentialWithReading]
    public let asOfSeq: Int

    public init(credentials: [CredentialWithReading], asOfSeq: Int) {
        self.credentials = credentials
        self.asOfSeq = asOfSeq
    }

    enum CodingKeys: String, CodingKey {
        case credentials
        case asOfSeq = "as_of_seq"
    }
}

/// `AddCredentialResult`: the credential's id and the helper request that
/// runs its checks (IN-23, IN-24).
public struct AddCredentialResult: Codable, Equatable, Sendable {
    public let credentialID: UUID
    public let helperRequestID: UUID

    public init(credentialID: UUID, helperRequestID: UUID) {
        self.credentialID = credentialID
        self.helperRequestID = helperRequestID
    }

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case helperRequestID = "helper_request_id"
    }
}
