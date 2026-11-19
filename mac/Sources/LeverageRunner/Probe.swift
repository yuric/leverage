import Foundation
import LeverageKit

/// `LeverageRunner probe`: the answering check of the add flow (PV-3). It
/// runs the test prompt once with the provider's check arguments, in a new
/// empty folder of its own, and exits 0 when the tool answers the word
/// "ready", 1 otherwise. It needs no seat token. The tool's output is never
/// logged: only whether it answered, or how it failed.
enum Probe {
    static func run(environment: [String: String], log: Log) async -> Int32 {
        let driver: ProcessToolDriver
        do {
            driver = try ProcessToolDriver(
                tool: ToolConfiguration(environment: environment, defaultTimeout: ToolConfiguration.probeTimeoutSeconds))
        } catch {
            log.error("probe: \(error)")
            return 1
        }
        let base = driver.tool.parentEnvironment[EnvironmentKeys.tmpdir].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("leverage-probe-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log.error("probe: no folder to run the check in")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            let answer = try await driver.run(prompt: Prompts.ready, in: folder, purpose: .check)
            guard AnswerParser.isReady(answer.text) else {
                log.warning("probe: \(driver.tool.provider.rawValue) answered something other than the word asked for")
                return 1
            }
            log.info("probe: \(driver.tool.provider.rawValue) answered")
            return 0
        } catch let failure as ToolFailure {
            log.warning("probe: \(driver.tool.provider.rawValue): \(failure)")
            return 1
        } catch {
            log.warning("probe: stopped")
            return 1
        }
    }
}
