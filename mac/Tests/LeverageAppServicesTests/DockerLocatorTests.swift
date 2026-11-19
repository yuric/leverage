import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageAppServices

@Suite("DockerLocator")
struct DockerLocatorTests {
    @Test("finds docker in the first folder of the list that has it, and looks nowhere else")
    func findsInGivenFolders() throws {
        let fake = try FakeDocker()
        let empty = try fake.folder.folder("empty")
        let probe = RecordingProbe()
        let locator = DockerLocator(folders: [empty, fake.binFolder], isExecutable: probe.probe)

        #expect(locator.locate()?.path == fake.docker.path)
        #expect(probe.paths.value == [
            empty.appendingPathComponent("docker").path, fake.docker.path,
        ])
    }

    @Test("answers nil when no folder has it")
    func missing() throws {
        let fake = try FakeDocker(withDocker: false)
        let probe = RecordingProbe()
        let locator = DockerLocator(folders: [fake.binFolder], isExecutable: probe.probe)

        #expect(locator.locate() == nil)
        #expect(probe.paths.value.allSatisfy { $0.hasPrefix(fake.root.path + "/") })
    }

    @Test("the app's folders are PK-3's four, in order")
    func applicationFolders() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(DockerLocator.applicationFolders(home: home).map(\.path) == [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/Users/someone/.docker/bin",
        ])
    }

    @Test("docker gets exactly HOME and the PATH of PK-2")
    func dockerEnvironment() {
        let environment = DockerLocator.environment(
            docker: URL(fileURLWithPath: "/somewhere/bin/docker"), home: URL(fileURLWithPath: "/Users/someone"))
        #expect(environment == [
            "HOME": "/Users/someone",
            "PATH": "/somewhere/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin",
        ])
    }

    @Test("the engine is answering only when docker info exits 0")
    func engineAnswering() async throws {
        let fake = try FakeDocker()
        let locator = DockerLocator(folders: [fake.binFolder])
        let docker = try #require(locator.locate())

        #expect(await locator.engineIsAnswering(docker: docker, home: fake.home, runner: SystemProcessRunner()) == false)
        fake.set("engine-running")
        #expect(await locator.engineIsAnswering(docker: docker, home: fake.home, runner: SystemProcessRunner()))
        #expect(fake.dockerCalls().map(\.arguments.first) == ["info", "info"])
    }
}
