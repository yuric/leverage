/// The name of every environment variable the Mac side reads or hands to a
/// child process. The process environment is the Mac side's one
/// configuration mechanism; this is the one home of the names.
public enum EnvironmentKeys {
    // Read by every Mac program.

    /// The API's address.
    public static let apiURL = "LEVERAGE_API_URL"

    // Read by the helper.

    /// The helper's token. Set only by the app's helper supervisor and by
    /// the end-to-end test.
    public static let helperToken = "LEVERAGE_HELPER_TOKEN"
    /// The runner program; the default is the one next to the helper.
    public static let runnerPath = "LEVERAGE_RUNNER_PATH"
    /// When set, the only folder searched for providers' tools (the
    /// stand-ins in tests).
    public static let toolDir = "LEVERAGE_TOOL_DIR"
    /// `memory` keeps pasted tokens out of the Keychain.
    public static let tokenStore = "LEVERAGE_TOKEN_STORE"
    /// The stand-in provider API address, accepted only by unbundled helpers.
    public static let providerAPIBase = "LEVERAGE_PROVIDER_API_BASE"
    /// The limit of one account's usage read, in seconds. Defaults to 15.
    public static let readTimeoutSeconds = "LEVERAGE_READ_TIMEOUT_SECONDS"

    // Read by the runner.

    /// The seat's token. Set only by the helper's launcher.
    public static let seatToken = "LEVERAGE_SEAT_TOKEN"
    public static let seatRole = "LEVERAGE_SEAT_ROLE"
    public static let provider = "LEVERAGE_PROVIDER"
    public static let model = "LEVERAGE_MODEL"
    public static let effort = "LEVERAGE_EFFORT"
    /// The tool the helper found.
    public static let toolPath = "LEVERAGE_TOOL_PATH"
    /// The account's settings folder; absent for a provider with one
    /// sign-in for the Mac.
    public static let settingsDir = "LEVERAGE_SETTINGS_DIR"
    /// Where task folders are made.
    public static let workRoot = "LEVERAGE_WORK_ROOT"
    /// The limit of one tool run, in seconds; the default is 1800.
    public static let toolTimeoutSeconds = "LEVERAGE_TOOL_TIMEOUT_SECONDS"
    /// Set to `1` only by `scripts/real_provider_run.sh`: lets the runner
    /// start Claude or Codex with no account folder of Leverage's own.
    public static let devToolLogin = "LEVERAGE_DEV_TOOL_LOGIN"
    /// The credential this run is on. Absent for a seat that connects on
    /// its own, and then nothing is detected (plan HM-19).
    public static let credentialID = "LEVERAGE_CREDENTIAL_ID"
    /// The work to continue at start, from the `start_seat` request's
    /// `params`; at most one of the two is set (plan HD-1, HD-9).
    public static let continueTaskID = "LEVERAGE_CONTINUE_TASK_ID"
    public static let continueReviewID = "LEVERAGE_CONTINUE_REVIEW_ID"

    // Read by the app, and the support folder by the helper too.

    /// Replaces `~/Library/Application Support/leverage`.
    public static let supportDir = "LEVERAGE_SUPPORT_DIR"
    /// The compose project name; the default is `leverage-app`.
    public static let composeProject = "LEVERAGE_COMPOSE_PROJECT"
    /// `memory` keeps the owner's session out of the Keychain.
    public static let sessionStore = "LEVERAGE_SESSION_STORE"
    /// `off` keeps the app from asking for or posting a notification. Set
    /// by the smoke run and by nothing else (plan HM-27).
    public static let notifications = "LEVERAGE_NOTIFICATIONS"

    // Read by `LeverageRunner eval` and `scripts/eval_rule.sh`, and by nothing
    // else (plan section 2.4).

    /// The name of the eval suite; without it neither runs.
    public static let eval = "LEVERAGE_EVAL"
    /// `1` for a run on real tools. A run needs exactly one of this and
    /// `LEVERAGE_TOOL_DIR` (the stand-ins). Only the managing agent's run
    /// sets it.
    public static let evalReal = "LEVERAGE_EVAL_REAL"

    // Read by tests.

    /// Switches the end-to-end tests on.
    public static let e2e = "LEVERAGE_E2E"
    /// Where the end-to-end tests keep each test's folder (support folder,
    /// logs, the secrets they used) for scripts/e2e_core_loop.sh's secret
    /// scan; unset, each test uses a temporary folder.
    public static let e2eFolder = "LEVERAGE_E2E_DIR"
    /// Names the provider of the developer check with real tools.
    public static let realProvider = "LEVERAGE_REAL_PROVIDER"
    /// The build lane of `mac/Package.swift`.
    public static let only = "LEVERAGE_ONLY"

    // System variables a child process may be given (ProviderCatalog's
    // allow-lists name them).

    public static let path = "PATH"
    public static let home = "HOME"
    public static let tmpdir = "TMPDIR"
    public static let lang = "LANG"
    public static let user = "USER"
}
