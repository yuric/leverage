import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageRunner

// The run's inputs from the environment (plan §2.4): fail closed without a
// seat token, and without an account folder for a provider that keeps one
// (PV-6).
@Suite("Runner configuration")
struct RunnerConfigurationTests {
    let folder: TemporaryFolder
    let account: URL
    let fakeToken = "lvs_made_up_seat_token_for_tests_only"

    init() throws {
        folder = try TemporaryFolder(prefix: "leverage-runner-config")
        account = try folder.folder("account")
    }

    func environment(_ provider: String = "claude", role: String = "builder") -> [String: String] {
        [
            "LEVERAGE_API_URL": "http://127.0.0.1:49152",
            "LEVERAGE_SEAT_TOKEN": fakeToken,
            "LEVERAGE_SEAT_ROLE": role,
            "LEVERAGE_PROVIDER": provider,
            "LEVERAGE_TOOL_PATH": "/opt/example/bin/\(provider)",
            "LEVERAGE_SETTINGS_DIR": account.path,
            "LEVERAGE_WORK_ROOT": folder.path("work").path,
            "HOME": folder.url.path,
            "TMPDIR": folder.url.path,
            "LANG": "en_US.UTF-8",
            "USER": "standin",
        ]
    }

    func refusal(_ change: (inout [String: String]) -> Void, base: [String: String]? = nil)
        -> RunnerConfigurationError? {
        var values = base ?? environment()
        change(&values)
        do {
            _ = try RunnerConfiguration(environment: values)
            return nil
        } catch let error as RunnerConfigurationError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    @Test("a complete environment is read")
    func reads() throws {
        var values = environment()
        values["LEVERAGE_MODEL"] = "claude-model-1"
        values["LEVERAGE_EFFORT"] = "high"
        values["LEVERAGE_TOOL_TIMEOUT_SECONDS"] = "120"
        let configuration = try RunnerConfiguration(environment: values)
        #expect(configuration.apiBaseURL.absoluteString == "http://127.0.0.1:49152")
        #expect(configuration.seatToken == fakeToken)
        #expect(configuration.role == .builder)
        #expect(configuration.tool.provider == .claude)
        #expect(configuration.tool.model == "claude-model-1")
        #expect(configuration.tool.effort == "high")
        #expect(configuration.tool.timeoutSeconds == 120)
        #expect(configuration.tool.accountFolder == account.path)
        #expect(configuration.workRoot.path == folder.path("work").path)
    }

    @Test("defaults: a tool run is limited to 1800 seconds; an empty model or effort is the tool's default")
    func defaults() throws {
        var values = environment()
        values["LEVERAGE_MODEL"] = ""
        values["LEVERAGE_EFFORT"] = ""
        let configuration = try RunnerConfiguration(environment: values)
        #expect(configuration.tool.timeoutSeconds == 1800)
        #expect(configuration.tool.model == nil)
        #expect(configuration.tool.effort == nil)
    }

    @Test("without a work root, task folders go under the support folder's work folder")
    func workRootDefault() throws {
        var values = environment()
        values["LEVERAGE_WORK_ROOT"] = nil
        values["LEVERAGE_SUPPORT_DIR"] = folder.path("support").path
        #expect(try RunnerConfiguration(environment: values).workRoot.path == folder.path("support", "work").path)
        values["LEVERAGE_SUPPORT_DIR"] = nil
        #expect(try RunnerConfiguration(environment: values).workRoot.path
                == folder.path("Library", "Application Support", "leverage", "work").path)
    }

    @Test("no seat token, or an empty one, is refused")
    func noToken() {
        #expect(refusal { $0["LEVERAGE_SEAT_TOKEN"] = nil } == .missing("LEVERAGE_SEAT_TOKEN"))
        #expect(refusal { $0["LEVERAGE_SEAT_TOKEN"] = "" } == .missing("LEVERAGE_SEAT_TOKEN"))
    }

    @Test("an unknown role or a provider that is not a login is refused")
    func roleAndProvider() {
        #expect(refusal { $0["LEVERAGE_SEAT_ROLE"] = nil } == .missing("LEVERAGE_SEAT_ROLE"))
        #expect(refusal { $0["LEVERAGE_SEAT_ROLE"] = "auditor" } == .unsupportedRole("auditor"))
        #expect(refusal { $0["LEVERAGE_PROVIDER"] = "claude_api" } == .unsupportedProvider("claude_api"))
        #expect(refusal { $0["LEVERAGE_PROVIDER"] = nil } == .missing("LEVERAGE_PROVIDER"))
    }

    @Test("the tool's path must be given and absolute")
    func toolPath() {
        #expect(refusal { $0["LEVERAGE_TOOL_PATH"] = nil } == .missing("LEVERAGE_TOOL_PATH"))
        #expect(refusal { $0["LEVERAGE_TOOL_PATH"] = "claude" } == .notAbsolute("LEVERAGE_TOOL_PATH"))
    }

    @Test("a time limit that is not a positive number of seconds is refused")
    func timeout() {
        #expect(refusal { $0["LEVERAGE_TOOL_TIMEOUT_SECONDS"] = "soon" } == .invalidTimeout("soon"))
        #expect(refusal { $0["LEVERAGE_TOOL_TIMEOUT_SECONDS"] = "0" } == .invalidTimeout("0"))
    }

    @Test("Claude or Codex with no account folder is refused unless the developer switch is set (PV-6)",
          arguments: ["claude", "codex"])
    func accountFolder(provider: String) throws {
        let base = environment(provider)
        let expected = Provider(rawValue: provider)!
        #expect(refusal({ $0["LEVERAGE_SETTINGS_DIR"] = nil }, base: base) == .noAccountFolder(expected))
        #expect(refusal({ $0["LEVERAGE_SETTINGS_DIR"] = "" }, base: base) == .noAccountFolder(expected))
        #expect(refusal({ $0["LEVERAGE_SETTINGS_DIR"] = nil; $0["LEVERAGE_DEV_TOOL_LOGIN"] = "yes" }, base: base)
                == .noAccountFolder(expected))

        var developer = base
        developer["LEVERAGE_SETTINGS_DIR"] = nil
        developer["LEVERAGE_DEV_TOOL_LOGIN"] = "1"
        let configuration = try RunnerConfiguration(environment: developer)
        #expect(configuration.tool.accountFolder == nil)
    }

    @Test("an account folder that does not exist is refused")
    func accountFolderMissing() {
        let missing = folder.path("no-such-account").path
        #expect(refusal { $0["LEVERAGE_SETTINGS_DIR"] = missing } == .accountFolderMissing(missing))
    }

    @Test("Gemini and Grok need no account folder", arguments: ["gemini", "grok"])
    func oneSignInForTheMac(provider: String) throws {
        var values = environment(provider)
        values["LEVERAGE_SETTINGS_DIR"] = nil
        let configuration = try RunnerConfiguration(environment: values)
        #expect(configuration.tool.accountFolder == nil)
    }

    @Test("a Gemini reviewer is refused: agy's plan mode did not answer a plain prompt (step 0, CL-8)")
    func geminiReviewer() {
        var values = environment("gemini", role: "reviewer")
        values["LEVERAGE_SETTINGS_DIR"] = nil
        #expect(refusal({ _ in }, base: values) == .reviewerNotOffered(.gemini))
    }

    @Test("General runs on every login", arguments: ["claude", "codex", "gemini", "grok"])
    func generalOnEveryLogin(provider: String) throws {
        var values = environment(provider, role: "general")
        if provider == "gemini" || provider == "grok" { values["LEVERAGE_SETTINGS_DIR"] = nil }
        let configuration = try RunnerConfiguration(environment: values)
        #expect(configuration.role == .general)
        #expect(configuration.tool.provider.rawValue == provider)
        #expect(configuration.continuing == nil)
    }

    @Test("General reads the task or review it was started with", arguments: ["claude", "gemini"])
    func generalContinuation(provider: String) throws {
        let id = UUID()
        var values = environment(provider, role: "general")
        if provider == "gemini" { values["LEVERAGE_SETTINGS_DIR"] = nil }

        values["LEVERAGE_CONTINUE_TASK_ID"] = id.contractString
        #expect(try RunnerConfiguration(environment: values).continuing == .task(id))

        values["LEVERAGE_CONTINUE_TASK_ID"] = nil
        values["LEVERAGE_CONTINUE_REVIEW_ID"] = id.contractString
        #expect(try RunnerConfiguration(environment: values).continuing == .review(id))
    }

    @Test("the configuration never prints the seat token")
    func noTokenInDescription() throws {
        let configuration = try RunnerConfiguration(environment: environment())
        #expect(!String(describing: configuration).contains(fakeToken))
        #expect(!String(reflecting: configuration).contains(fakeToken))
        var dumped = ""
        dump(configuration, to: &dumped)
        #expect(!dumped.contains(fakeToken))
    }

    @Test("the tool's own settings keep no Leverage variable")
    func toolBaseEnvironment() throws {
        var values = environment()
        values["LEVERAGE_HELPER_TOKEN"] = "lvh_made_up_helper_token"
        let tool = try RunnerConfiguration(environment: values).tool
        #expect(tool.parentEnvironment.keys.allSatisfy { !$0.hasPrefix("LEVERAGE_") })
        #expect(tool.toolEnvironment.keys.allSatisfy { !$0.hasPrefix("LEVERAGE_") })
    }

    // MARK: Milestone 3's inputs (plan §2.4, HD-9, HM-19)

    @Test("the credential the run is on is read; absent, the run has none")
    func credential() throws {
        let id = UUID()
        var values = environment()
        values["LEVERAGE_CREDENTIAL_ID"] = id.contractString
        #expect(try RunnerConfiguration(environment: values).credentialID == id)
        #expect(try RunnerConfiguration(environment: environment()).credentialID == nil)
        values["LEVERAGE_CREDENTIAL_ID"] = ""
        #expect(try RunnerConfiguration(environment: values).credentialID == nil)
    }

    @Test("a credential that is not an id is refused")
    func credentialNotAnID() {
        #expect(refusal { $0["LEVERAGE_CREDENTIAL_ID"] = "cred-1" } == .notAnIdentifier("LEVERAGE_CREDENTIAL_ID"))
    }

    @Test("a builder reads the task to continue, a reviewer the review; neither, nothing")
    func continuing() throws {
        let taskID = UUID()
        let reviewID = UUID()
        var builder = environment()
        builder["LEVERAGE_CONTINUE_TASK_ID"] = taskID.contractString
        #expect(try RunnerConfiguration(environment: builder).continuing == .task(taskID))
        var reviewer = environment(role: "reviewer")
        reviewer["LEVERAGE_CONTINUE_REVIEW_ID"] = reviewID.contractString
        #expect(try RunnerConfiguration(environment: reviewer).continuing == .review(reviewID))
        #expect(try RunnerConfiguration(environment: environment()).continuing == nil)
    }

    @Test("both works to continue, work of the other role, or a value that is not an id is refused")
    func continuingRefused() {
        let id = UUID().contractString
        #expect(refusal {
            $0["LEVERAGE_CONTINUE_TASK_ID"] = id
            $0["LEVERAGE_CONTINUE_REVIEW_ID"] = UUID().contractString
        } == .twoWorksToContinue)
        #expect(refusal { $0["LEVERAGE_CONTINUE_REVIEW_ID"] = id } == .workNotForRole("LEVERAGE_CONTINUE_REVIEW_ID"))
        #expect(refusal({ $0["LEVERAGE_CONTINUE_TASK_ID"] = id }, base: environment(role: "reviewer"))
                == .workNotForRole("LEVERAGE_CONTINUE_TASK_ID"))
        #expect(refusal { $0["LEVERAGE_CONTINUE_TASK_ID"] = "task-1" } == .notAnIdentifier("LEVERAGE_CONTINUE_TASK_ID"))
    }

    @Test("the probe needs no seat token and no role")
    func probeConfiguration() throws {
        var values = environment()
        values["LEVERAGE_SEAT_TOKEN"] = nil
        values["LEVERAGE_SEAT_ROLE"] = nil
        let tool = try ToolConfiguration(environment: values)
        #expect(tool.provider == .claude)
    }

    // Milestone 4: the planner and the orchestrator are run like a builder
    // (plan section 2.2, §0.1 fact 12), on any login, Gemini's included:
    // a job's run is the answering check, never agy's plan mode (fact 27).
    @Test("the planner and the orchestrator are run, on every login", arguments: ["planner", "orchestrator"])
    func jobRoles(role: String) throws {
        for provider in ["claude", "codex", "gemini", "grok"] {
            var values = environment(provider, role: role)
            if provider == "gemini" || provider == "grok" { values["LEVERAGE_SETTINGS_DIR"] = nil }
            let configuration = try RunnerConfiguration(environment: values)
            #expect(configuration.role.rawValue == role)
        }
    }

    @Test("a job role is started to continue no task and no review")
    func jobRoleContinues() {
        let task = UUID().contractString
        #expect(refusal({ $0["LEVERAGE_CONTINUE_TASK_ID"] = task }, base: environment(role: "orchestrator"))
            == .workNotForRole("LEVERAGE_CONTINUE_TASK_ID"))
        #expect(refusal({ $0["LEVERAGE_CONTINUE_REVIEW_ID"] = task }, base: environment(role: "planner"))
            == .workNotForRole("LEVERAGE_CONTINUE_REVIEW_ID"))
    }

    @Test("the arguments name a seat's run, the probe, the version, or eval with what follows it")
    func subcommands() {
        #expect(RunnerSubcommand(arguments: []) == .seat)
        #expect(RunnerSubcommand(arguments: ["probe"]) == .probe)
        #expect(RunnerSubcommand(arguments: ["--version"]) == .version)
        #expect(RunnerSubcommand(arguments: ["eval"]) == .eval([]))
        #expect(RunnerSubcommand(arguments: ["eval", "--inputs", "/tmp/in.jsonl", "--provider", "claude"])
            == .eval(["--inputs", "/tmp/in.jsonl", "--provider", "claude"]))
        #expect(RunnerSubcommand(arguments: ["evaluate"]) == .unknown("evaluate"))
    }
}
