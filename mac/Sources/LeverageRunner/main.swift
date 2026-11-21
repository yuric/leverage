import Foundation
import LeverageKit

// The reference runner (plan §2.2): one seat's run, started by the helper's
// launcher with its environment (plan §2.4), `LeverageRunner probe`, the
// add flow's answering check, or `LeverageRunner eval`, the eval suite's
// harness (milestone 4). It reads its environment, builds the loop,
// and turns SIGTERM or SIGINT into a stop: the tool is ended, what the seat
// holds is given back, and it exits 0 (CL-23). The helper that started it
// going away (a crash, SIGKILL) is the same stop (RunnerParent, PK-8). When
// the account stops (a limit or a sign-out) it exits 5 and prints one
// report line on standard output, for the helper to send (HD-5, HD-6).

let environment = ProcessInfo.processInfo.environment

switch RunnerSubcommand(arguments: Array(CommandLine.arguments.dropFirst())) {
case .probe:
    exit(await Probe.run(environment: environment, log: Log(component: "probe")))
case .eval(let arguments):
    // The eval harness (milestone 4 plan section 2.2, RV-6): no seat, no server.
    exit(await EvalRun.run(arguments: arguments, environment: environment))
case .version:
    print("LeverageRunner \(leverageMacVersion)")
    exit(0)
case .seat:
    break
case .unknown(let other):
    Log(component: "runner").error("unknown argument \(other); the runner takes none, probe or eval")
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
    driver: driver, workRoot: configuration.workRoot, home: configuration.tool.home,
    interruption: .runner(tool: configuration.tool, credentialID: configuration.credentialID, log: log),
    continuing: configuration.continuing, log: log)

let stopSignals = loop.stopOnSignals([SIGTERM, SIGINT])
let parentWatch = RunnerParent.watch { [loop] in
    log.warning("the helper that started the runner is gone; stopping")
    loop.stop()
}

log.info("started: \(configuration)")
let code = await loop.run()
parentWatch?.cancel()
stopSignals.forEach { $0.cancel() }
// Code 5: the report line, the runner's one line on standard output (HD-6).
exit(RunnerEnd.finish(code: code, report: loop.endReport, log: log, write: RunnerEnd.standardOutput))
