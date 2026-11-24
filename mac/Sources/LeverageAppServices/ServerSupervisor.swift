import Foundation
import LeverageKit

/// Starts the server on this Mac and reports its state (plan PK-2, PK-3):
/// finds `docker`, starts Docker Desktop if its engine is not answering,
/// checks that the API image is there, writes the server folder, runs
/// `docker compose -p <project> up -d` in it, and waits for `GET /v1/health`.
/// The containers restart with Docker and are left running when the app
/// quits, so nothing here stops them.
public actor ServerSupervisor: ServerSupervising {
    public struct Configuration: Sendable {
        public var supportFolder: URL
        /// The folders searched for `docker`, in order: PK-3's in the app.
        public var dockerFolders: [URL]
        /// The owner's home folder, which every `docker` command gets.
        public var home: URL
        /// The compose file in the app bundle.
        public var composeSource: URL
        /// The tag of the `leverage-api` image the bundle was built with.
        public var imageTag: String
        public var composeProject: String
        /// The bundled MCP executable, whose path the API gives to MCP clients.
        public var mcpProgram: URL?
        /// The program that starts Docker Desktop, run as `open -a Docker`.
        public var openProgram = "/usr/bin/open"
        /// How long Docker Desktop is given to answer after it was opened.
        public var dockerStartTimeout: Duration = .seconds(120)
        /// How long the API is given to answer its health check.
        public var healthTimeout: Duration = .seconds(180)
        public var pollInterval: Duration = .seconds(1)
        /// The limit of `docker compose up`, which may load images.
        public var composeTimeLimit: Duration = .seconds(600)

        public init(
            supportFolder: URL, dockerFolders: [URL], home: URL, composeSource: URL, imageTag: String,
            composeProject: String = Configuration.defaultComposeProject, mcpProgram: URL? = nil
        ) {
            self.supportFolder = supportFolder
            self.dockerFolders = dockerFolders
            self.home = home
            self.composeSource = composeSource
            self.imageTag = imageTag
            self.composeProject = composeProject
            self.mcpProgram = mcpProgram
        }

        /// The project name keeps the owner's data apart from a developer's
        /// `leverage` project (PK-2).
        public static let defaultComposeProject = "leverage-app"

        /// `LEVERAGE_COMPOSE_PROJECT`, else `leverage-app`.
        public static func composeProject(environment: [String: String]) -> String {
            guard let name = environment[EnvironmentKeys.composeProject], !name.isEmpty else {
                return defaultComposeProject
            }
            return name
        }

        /// The `leverage-api` image reference.
        public var image: String { "leverage-api:\(imageTag)" }
    }

    private let configuration: Configuration
    private let runner: any ProcessRunning
    private let locator: DockerLocator
    private let isPortFree: @Sendable (Int) -> Bool
    private let healthCheck: @Sendable (URL) async -> Bool
    private let log: Log

    private var current: ServerState = .notStarted
    private var starting: Task<ServerState, Never>?

    public init(
        configuration: Configuration,
        runner: any ProcessRunning = SystemProcessRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = DockerLocator.fileIsExecutable,
        isPortFree: @escaping @Sendable (Int) -> Bool = ServerFiles.portIsFree,
        healthCheck: @escaping @Sendable (URL) async -> Bool = ServerSupervisor.apiAnswersHealth,
        log: Log = Log(component: "app")
    ) {
        self.configuration = configuration
        self.runner = runner
        self.locator = DockerLocator(folders: configuration.dockerFolders, isExecutable: isExecutable)
        self.isPortFree = isPortFree
        self.healthCheck = healthCheck
        self.log = log
    }

    public func state() async -> ServerState { current }

    /// Starts what is not running yet. A call while a start is under way
    /// waits for that start; a call after a state the owner can act on
    /// (Docker missing, not starting, the image missing, failed) tries again.
    /// After running, a call asks the server's health first: it answers
    /// running only while the server answers, and otherwise goes through
    /// Docker again (Docker Desktop or the containers may have stopped while
    /// the app was open).
    public func start() async -> ServerState {
        if let starting { return await starting.value }
        if case .running(let url) = current {
            if await healthCheck(url) { return current }
            log.warning("the server no longer answers at \(url.absoluteString); starting it again")
            if let starting { return await starting.value }
        }
        let task = Task { await self.run() }
        starting = task
        let reached = await task.value
        starting = nil
        return reached
    }

    /// The default health check: `GET /v1/health` answers `ok`.
    public static let apiAnswersHealth: @Sendable (URL) async -> Bool = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let health = try? await LeverageClient(baseURL: url, session: session).health() else {
            return false
        }
        return health.status == "ok"
    }

    // MARK: - The steps

    private func move(to state: ServerState) -> ServerState {
        current = state
        return state
    }

    private func run() async -> ServerState {
        guard let docker = locator.locate() else {
            log.warning("no docker program in \(configuration.dockerFolders.map(\.path).joined(separator: ", "))")
            return move(to: .dockerMissing)
        }
        guard await dockerAnswers(docker) else { return current }

        let image = await self.docker(
            docker, ["image", "inspect", "--format", "{{.Id}}", configuration.image], timeLimit: .seconds(30))
        guard let image, image.succeeded else {
            log.warning("the image \(configuration.image) is not in this Mac's Docker")
            return move(to: .imageMissing)
        }

        let settings: ServerSettings
        do {
            settings = try ServerFiles(supportFolder: configuration.supportFolder).prepare(
                composeSource: configuration.composeSource, imageTag: configuration.imageTag,
                isPortFree: isPortFree)
        } catch {
            return failed("the server folder could not be written: \(error)")
        }

        _ = move(to: .starting)
        let folder = settings.folder.path
        var environment = DockerLocator.environment(docker: docker, home: configuration.home)
        environment[EnvironmentKeys.mcpCommand] = configuration.mcpProgram?.path
        let up = await self.docker(
            docker,
            ["compose", "--project-directory", folder, "-f", folder + "/compose.yaml",
             "-p", configuration.composeProject, "up", "-d"],
            workingDirectory: folder, environment: environment, timeLimit: configuration.composeTimeLimit)
        guard let up else { return failed("docker compose up could not be started") }
        guard up.succeeded else {
            return failed("docker compose up failed (\(up.exitDescription)): \(up.lastLine)")
        }

        let deadline = ContinuousClock.now + configuration.healthTimeout
        while true {
            if await healthCheck(settings.apiBaseURL) {
                log.info("the server answers at \(settings.apiBaseURL.absoluteString)")
                return move(to: .running(apiBaseURL: settings.apiBaseURL))
            }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: configuration.pollInterval)
        }
        return failed("the server did not answer its health check at \(settings.apiBaseURL.absoluteString)")
    }

    /// True when the engine answers, opening Docker Desktop first if needed;
    /// otherwise the state says why not.
    private func dockerAnswers(_ docker: URL) async -> Bool {
        if await locator.engineIsAnswering(docker: docker, home: configuration.home, runner: runner) {
            return true
        }
        _ = move(to: .dockerStarting)
        log.info("Docker is not answering; opening Docker Desktop")
        let opened = try? await runner.run(SubprocessRequest(
            executable: configuration.openProgram, arguments: ["-a", "Docker"],
            environment: [EnvironmentKeys.home: configuration.home.path, EnvironmentKeys.path: "/usr/bin:/bin"],
            timeLimit: .seconds(30)))
        if opened?.succeeded != true {
            log.warning("open -a Docker did not succeed: \(opened.map(\.lastLine) ?? "not started")")
        }
        let deadline = ContinuousClock.now + configuration.dockerStartTimeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: configuration.pollInterval)
            if await locator.engineIsAnswering(docker: docker, home: configuration.home, runner: runner) {
                return true
            }
        }
        log.warning("Docker Desktop did not answer in time")
        _ = move(to: .dockerNotStarting)
        return false
    }

    private func docker(
        _ docker: URL, _ arguments: [String], workingDirectory: String? = nil,
        environment: [String: String]? = nil, timeLimit: Duration
    ) async -> SubprocessResult? {
        let request = SubprocessRequest(
            executable: docker.path, arguments: arguments,
            environment: environment ?? DockerLocator.environment(docker: docker, home: configuration.home),
            workingDirectory: workingDirectory, timeLimit: timeLimit)
        do {
            return try await runner.run(request)
        } catch {
            log.error("docker \(arguments.first ?? "") could not be started: \(error)")
            return nil
        }
    }

    private func failed(_ reason: String) -> ServerState {
        let line = Redaction.redact(reason)
        log.error(line)
        return move(to: .failed(reason: line))
    }
}
