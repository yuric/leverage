import Foundation
import LeverageKit

// The reference runner (plan §2.2): one seat's run, started by the helper's
// launcher with its environment (plan §2.4), or `LeverageRunner probe`, the
// add flow's answering check. It reads its environment, builds the loop,
// and turns SIGTERM or SIGINT into a stop: the tool is ended, what the seat
// holds is given back, and it exits 0 (CL-23).

let environment = ProcessInfo.processInfo.environment

switch CommandLine.arguments.dropFirst().first {
case "probe":
    exit(await Probe.run(environment: environment, log: Log(component: "probe")))
case "--version":
    print("LeverageRunner \(leverageMacVersion)")
    exit(0)
case nil:
    break
case let other?:
    Log(component: "runner").error("unknown argument \(other); the runner takes none, or probe")
    exit(RunnerExit.configuration.rawValue)
}

let log = Log(component: "runner")
let configuration: RunnerConfiguration
do {
    configuration = try RunnerConfiguration(environment: environment)
} catch {
    log.error("not started: \(error)")
    exit(RunnerExit.configuration.rawValue)
}
let driver: ProcessToolDriver
do {
    driver = try ProcessToolDriver(tool: configuration.tool)
} catch {
    log.error("not started: \(error)")
    exit(RunnerExit.configuration.rawValue)
}

let loop = RunnerLoop(
    role: configuration.role,
    api: AgentClient(baseURL: configuration.apiBaseURL, seatToken: configuration.seatToken),
    driver: driver, workRoot: configuration.workRoot, home: configuration.tool.home, log: log)

let stopSignals = loop.stopOnSignals([SIGTERM, SIGINT])

log.info("started: \(configuration)")
let code = await loop.run()
stopSignals.forEach { $0.cancel() }
exit(code)
