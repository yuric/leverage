import Foundation
import LeverageKit
import LeverageTestSupport

let credentialsEnabled = ProcessInfo.processInfo.environment[EnvironmentKeys.e2e] == "credentials"

struct CredentialsHarness {
    static let deadline = Patience.seconds(120)

    let folder: TestFolder
    let tools: StandInTools
    let work: URL
    let owner: OwnerClient
    let follower: EventFollower
    let helper: RunningHelper
    let providerAPI: RunningProviderAPI

    var handoffWorld: HandoffWorld {
        HandoffWorld(folder: folder, tools: tools, work: work, owner: owner, follower: follower, helper: helper)
    }

    static func start(
        name: String, tokens: [String: StandInScenario.TokenDirective] = [:]
    ) async throws -> CredentialsHarness {
        let folder = try TestFolder(name)
        let tools = try StandIns.copy(into: folder.url)
        let work = try folder.folder("work")
        let owner = try await EndToEnd.owner()
        try await owner.turnShippedRulesOff()
        guard let helperToken = try await owner.issueHelperToken(
            name: "Credentials end-to-end Mac", idempotencyKey: IdempotencyKey().value) else {
            throw EndToEndFailure("issue_helper_token answered no token")
        }
        try folder.record(secrets: [
            EndToEnd.ownerPassword, owner.transport.token ?? "", helperToken,
            StandIns.statusEmail, StandIns.statusOrganisation,
        ].filter { !$0.isEmpty })
        let follower = try await EventFollower.fromNow(owner: owner)
        let providerAPI = try await RunningProviderAPI.start(tools: tools, tokens: tokens)
        do {
            let helper = try RunningHelper(token: helperToken, folder: folder, tools: tools,
                                           providerAPIBase: providerAPI.endpoint)
            return CredentialsHarness(folder: folder, tools: tools, work: work, owner: owner,
                                      follower: follower, helper: helper, providerAPI: providerAPI)
        } catch {
            await providerAPI.stop()
            throw error
        }
    }

    func stop() async {
        await helper.stop()
        await providerAPI.stop()
    }
}

struct RunningProviderAPI: Sendable {
    struct Call: Decodable, Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    let endpoint: URL
    private let tools: StandInTools
    private let process: RunningSubprocess

    static func start(
        tools: StandInTools, tokens: [String: StandInScenario.TokenDirective]
    ) async throws -> RunningProviderAPI {
        let scenario = try tools.writeProviderAPIScenario(tokens: tokens)
        let portFile = scenario.deletingLastPathComponent().appendingPathComponent("port")
        let environment = Subprocess.environment(allowing: ["PATH"], from: ProcessInfo.processInfo.environment)
        let process = try Subprocess.start(.init(
            executable: "/usr/bin/env",
            arguments: ["python3", "-I", tools.providerAPI.path, "--scenario", scenario.path,
                        "--port-file", portFile.path], environment: environment,
            gracePeriod: .seconds(1)))
        do {
            try await eventually("the provider API published its port", deadline: Patience.seconds(30)) {
                try endpoint(from: portFile) != nil
            }
            guard let endpoint = try endpoint(from: portFile) else {
                throw EndToEndFailure("the provider API's port file disappeared")
            }
            return RunningProviderAPI(endpoint: endpoint, tools: tools, process: process)
        } catch {
            process.stop()
            _ = await process.wait()
            throw error
        }
    }

    static func endpoint(from portFile: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: portFile.path) else { return nil }
        let text = try String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(text), port > 0, let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw EndToEndFailure("the provider API published an invalid port")
        }
        return url
    }

    func update(tokens: [String: StandInScenario.TokenDirective]) throws {
        try tools.writeProviderAPIScenario(tokens: tokens)
    }

    func calls() throws -> [Call] {
        let record = tools.state.appendingPathComponent("provider-api/calls.jsonl")
        guard FileManager.default.fileExists(atPath: record.path) else { return [] }
        return try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Call.self, from: Data($0.utf8)) }
    }

    func stop() async {
        process.stop()
        _ = await process.wait()
    }
}
