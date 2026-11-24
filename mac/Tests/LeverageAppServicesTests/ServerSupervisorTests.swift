import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

@Suite("ServerSupervisor")
struct ServerSupervisorTests {
    /// A supervisor that searches only the fake's `bin` folder, opens Docker
    /// Desktop with the fake `open`, and checks health through `healthy`.
    private func supervisor(
        _ fake: FakeDocker,
        runner: any ProcessRunning = SystemProcessRunner(),
        probe: RecordingProbe = RecordingProbe(),
        dockerStartTimeout: Duration = .seconds(10),
        healthTimeout: Duration = .seconds(10),
        mcpProgram: URL? = nil,
        healthy: @escaping @Sendable (URL) async -> Bool
    ) -> ServerSupervisor {
        var configuration = ServerSupervisor.Configuration(
            supportFolder: fake.supportFolder,
            dockerFolders: [fake.binFolder],
            home: fake.home,
            composeSource: fake.composeSource,
            imageTag: "0.1.0-made-up", mcpProgram: mcpProgram)
        configuration.openProgram = fake.openProgram.path
        configuration.dockerStartTimeout = dockerStartTimeout
        configuration.healthTimeout = healthTimeout
        configuration.pollInterval = .milliseconds(20)
        return ServerSupervisor(
            configuration: configuration, runner: runner, isExecutable: probe.probe,
            isPortFree: { _ in true }, healthCheck: healthy, log: Log(component: "test", write: { _ in }))
    }

    @Test("only compose up gets the bundled MCP command, with spaces preserved")
    func composeMCPCommand() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        let mcpProgram = fake.root.appendingPathComponent("Applications With Spaces/Leverage.app/Contents/MacOS/LeverageMCP")
        let server = supervisor(
            fake, healthTimeout: Patience.scaled(.seconds(30)), mcpProgram: mcpProgram,
            healthy: { _ in fake.isSet("compose-up") })

        #expect(await server.start() == .running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
        let calls = fake.dockerCalls()
        #expect(calls.map { $0.arguments.first } == ["info", "image", "compose"])
        #expect(calls.map { $0.environment["LEVERAGE_MCP_COMMAND"] } == [nil, nil, mcpProgram.path])
    }

    @Test("no Docker: dockerMissing, nothing run, and no path outside the given folder looked at")
    func noDocker() async throws {
        let fake = try FakeDocker(withDocker: false)
        let runner = RecordingRunner()
        let probe = RecordingProbe()
        let server = supervisor(fake, runner: runner, probe: probe, healthy: { _ in true })

        #expect(await server.start() == .dockerMissing)
        #expect(await server.state() == .dockerMissing)
        #expect(runner.executables.value.isEmpty)
        #expect(!probe.paths.value.isEmpty)
        #expect(probe.paths.value.allSatisfy { $0.hasPrefix(fake.root.path + "/") })
    }

    @Test("Docker stopped then started: opens Docker Desktop, waits for the engine, then runs")
    func dockerStoppedThenStarted() async throws {
        let fake = try FakeDocker()
        fake.set("docker-starts-when-opened")
        fake.set("image-present")
        let runner = RecordingRunner()
        let probe = RecordingProbe()
        let server = supervisor(fake, runner: runner, probe: probe, healthy: { _ in fake.isSet("compose-up") })

        let reached = await server.start()
        #expect(reached == .running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
        #expect(fake.openCalls().map(\.arguments) == [["-a", "Docker"]])
        let commands = fake.dockerCalls().map { $0.arguments.first ?? "" }
        #expect(commands.first == "info")
        #expect(commands.suffix(3) == ["info", "image", "compose"])
        // Every program run and every path looked at is inside the fake.
        #expect(runner.executables.value.allSatisfy { $0.hasPrefix(fake.root.path + "/") })
        #expect(probe.paths.value.allSatisfy { $0.hasPrefix(fake.root.path + "/") })
    }

    @Test("Docker that does not start in time: dockerNotStarting, and compose is not run")
    func dockerNotStarting() async throws {
        let fake = try FakeDocker()
        let server = supervisor(fake, dockerStartTimeout: .milliseconds(300), healthy: { _ in true })

        #expect(await server.start() == .dockerNotStarting)
        #expect(fake.openCalls().count == 1)
        #expect(!fake.dockerCalls().contains { $0.arguments.first == "compose" })
    }

    @Test("a missing image: imageMissing, and compose is not run")
    func missingImage() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        let server = supervisor(fake, healthy: { _ in true })

        #expect(await server.start() == .imageMissing)
        let image = try #require(fake.dockerCalls().first { $0.arguments.first == "image" })
        #expect(image.arguments == ["image", "inspect", "--format", "{{.Id}}", "leverage-api:0.1.0-made-up"])
        #expect(!fake.dockerCalls().contains { $0.arguments.first == "compose" })
        #expect(fake.openCalls().isEmpty)
    }

    @Test("compose up in the server folder, then waits until healthy")
    func composeUpThenHealthy() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        let asked = Locked<[URL]>([])
        let server = supervisor(fake, healthy: { url in
            let count = asked.update { $0.append(url); return $0.count }
            return fake.isSet("compose-up") && count >= 3
        })

        #expect(await server.start() == .running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
        #expect(await server.state() == .running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
        #expect(asked.value.count == 3)
        #expect(asked.value.allSatisfy { $0.absoluteString == "http://127.0.0.1:47130" })

        let compose = try #require(fake.dockerCalls().first { $0.arguments.first == "compose" })
        let serverFolder = fake.supportFolder.appendingPathComponent("server").path
        #expect(compose.arguments == [
            "compose", "--project-directory", serverFolder, "-f", serverFolder + "/compose.yaml",
            "-p", "leverage-app", "up", "-d",
        ])
        #expect(compose.workingDirectory == serverFolder)
        #expect(fake.openCalls().isEmpty)
    }

    @Test("every docker command gets exactly HOME and the PATH of PK-2")
    func dockerEnvironment() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        let server = supervisor(fake, healthy: { _ in fake.isSet("compose-up") })

        _ = await server.start()
        let calls = fake.dockerCalls()
        #expect(calls.count == 3)
        for call in calls {
            #expect(call.environment == [
                "HOME": fake.home.path,
                "PATH": "\(fake.binFolder.path):/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin",
            ])
        }
    }

    @Test("the compose project name comes from LEVERAGE_COMPOSE_PROJECT, default leverage-app")
    func projectName() {
        #expect(ServerSupervisor.Configuration.composeProject(environment: [:]) == "leverage-app")
        #expect(ServerSupervisor.Configuration.composeProject(environment: ["LEVERAGE_COMPOSE_PROJECT": "smoke-1"])
            == "smoke-1")
        #expect(ServerSupervisor.Configuration.composeProject(environment: ["LEVERAGE_COMPOSE_PROJECT": ""])
            == "leverage-app")
    }

    @Test("compose up failing: failed, with a reason for the log")
    func composeFails() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        fake.set("compose-fails")
        let server = supervisor(fake, healthy: { _ in true })

        guard case .failed(let reason) = await server.start() else {
            Issue.record("expected failed")
            return
        }
        #expect(reason.contains("compose up failed, made up"))
    }

    @Test("a server that never answers its health check: failed")
    func neverHealthy() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        let server = supervisor(fake, healthTimeout: .milliseconds(200), healthy: { _ in false })

        guard case .failed = await server.start() else {
            Issue.record("expected failed")
            return
        }
    }

    @Test("Check again after Docker was missing finds it once installed")
    func checkAgain() async throws {
        let fake = try FakeDocker()
        let elsewhere = try fake.folder.folder("not-yet")
        var configuration = ServerSupervisor.Configuration(
            supportFolder: fake.supportFolder, dockerFolders: [elsewhere], home: fake.home,
            composeSource: fake.composeSource, imageTag: "0.1.0-made-up")
        configuration.openProgram = fake.openProgram.path
        configuration.pollInterval = .milliseconds(20)
        fake.set("engine-running")
        fake.set("image-present")
        let server = ServerSupervisor(
            configuration: configuration, isPortFree: { _ in true },
            healthCheck: { _ in fake.isSet("compose-up") }, log: Log(component: "test", write: { _ in }))

        #expect(await server.start() == .dockerMissing)
        try FileManager.default.copyItem(at: fake.docker, to: elsewhere.appendingPathComponent("docker"))
        #expect(await server.start() == .running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
    }

    @Test("after running, a start whose server stopped answering goes through Docker again and opens it once")
    func runningThenDockerQuit() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        fake.set("docker-starts-when-opened")
        let server = supervisor(fake, healthy: { _ in fake.isSet("compose-up") })
        let running = ServerState.running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!)
        #expect(await server.start() == running)
        #expect(fake.openCalls().isEmpty)

        // Docker Desktop quits: the engine and the containers are gone.
        fake.set("engine-running", false)
        fake.set("compose-up", false)

        #expect(await server.start() == running)
        #expect(fake.openCalls().map(\.arguments) == [["-a", "Docker"]])
        #expect(fake.dockerCalls().filter { $0.arguments.first == "compose" }.count == 2)
    }

    @Test("a start while the server still answers runs nothing")
    func runningStillAnswers() async throws {
        let fake = try FakeDocker()
        fake.set("engine-running")
        fake.set("image-present")
        let server = supervisor(fake, healthy: { _ in fake.isSet("compose-up") })
        _ = await server.start()
        let before = fake.calls().count

        #expect(await server.start() == .running(apiBaseURL: URL(string: "http://127.0.0.1:47130")!))
        #expect(fake.calls().count == before)
    }
}
