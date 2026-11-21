import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("HealthLineModel")
struct HealthLineModelTests {
    private func makeModel(
        health: @escaping @Sendable () async throws -> SystemHealth, helper: FakeHelper = FakeAppRuntime().fakeHelper,
        interval: Duration = .milliseconds(5)
    ) -> (HealthLineModel, FakeOwnerAPI, FakeHelper) {
        let owner = FakeOwnerAPI()
        owner.script { $0.systemHealth = health }
        return (HealthLineModel(owner: owner, helper: helper, interval: interval), owner, helper)
    }

    @Test("before the first answer it says it is checking, not that all is well")
    func startsChecking() {
        let (model, _, _) = makeModel(health: { ShellFixtures.health() })
        #expect(model.status == .checking)
        #expect(model.sentence == .healthChecking)
    }

    @Test("a healthy answer reads System is running")
    func running() async {
        let (model, owner, _) = makeModel(health: { ShellFixtures.health() })
        await model.refresh()
        #expect(model.status == .running)
        #expect(model.sentence.text == "System is running")
        #expect(model.tone == .good)
        #expect(!model.offersTryAgain)
        #expect(owner.calls.map(\.operation) == [.getSystemHealth])
    }

    @Test("a sweep that is more than two minutes late reads Background work is late")
    func late() async {
        let (model, _, _) = makeModel(health: { ShellFixtures.health(sweepLate: true) })
        await model.refresh()
        #expect(model.status == .late)
        #expect(model.sentence.text == "Background work is late")
        #expect(model.tone == .warning)
    }

    @Test("a helper that gave up reads Agents are not running on this Mac, with Try again")
    func agentsStopped() async {
        let helper = FakeAppRuntime().fakeHelper
        helper.current.value = .stoppedTrying
        let (model, _, _) = makeModel(health: { ShellFixtures.health() }, helper: helper)
        await model.refresh()
        #expect(model.status == .agentsStopped)
        #expect(model.sentence.text == "Agents are not running on this Mac")
        #expect(model.offersTryAgain)
        #expect(model.tone == .warning)
    }

    @Test("with no server to start again, leverage not answering offers no Try again")
    func unreachableWithoutServer() async {
        let (model, _, _) = makeModel(health: { throw URLError(.cannotConnectToHost) })
        await model.refresh()
        #expect(model.status == .unreachable)
        #expect(!model.offersTryAgain)
    }

    @Test("a helper that is starting, restarting, stopped or not started does not change the line")
    func otherHelperStates() async {
        for state in [HelperState.notStarted, .starting, .running, .restarting(attempt: 2), .stopped] {
            let helper = FakeAppRuntime().fakeHelper
            helper.current.value = state
            let (model, _, _) = makeModel(health: { ShellFixtures.health() }, helper: helper)
            await model.refresh()
            #expect(model.status == .running, "helper \(state)")
        }
    }

    @Test("when leverage does not answer it reads Can't reach leverage on this Mac, and recovers when it does")
    func unreachable() async {
        let answering = Locked(false)
        let (model, _, _) = makeModel(health: {
            if answering.value { return ShellFixtures.health() }
            throw URLError(.cannotConnectToHost)
        })
        await model.refresh()
        #expect(model.status == .unreachable)
        #expect(model.sentence.text == "Can't reach leverage on this Mac")
        #expect(model.tone == .bad)

        answering.value = true
        await model.refresh()
        #expect(model.status == .running)
    }

    @Test("when leverage does not answer, Try again asks the server to start again, then reads the line again")
    func unreachableTryAgain() async {
        let answering = Locked(false)
        let owner = FakeOwnerAPI()
        owner.script {
            $0.systemHealth = {
                if answering.value { return ShellFixtures.health() }
                throw URLError(.cannotConnectToHost)
            }
        }
        let server = FakeServer()
        let model = HealthLineModel(owner: owner, helper: FakeAppRuntime().fakeHelper, server: server,
                                    interval: .milliseconds(5))
        await model.refresh()
        #expect(model.status == .unreachable)
        #expect(model.offersTryAgain)

        answering.value = true
        await model.tryAgain()

        #expect(server.startCount.value == 1)
        #expect(model.status == .running)
    }


    @Test("not being reachable outranks a helper that gave up, which outranks a late sweep")
    func precedence() async {
        let helper = FakeAppRuntime().fakeHelper
        helper.current.value = .stoppedTrying
        let (both, _, _) = makeModel(health: { ShellFixtures.health(sweepLate: true) }, helper: helper)
        await both.refresh()
        #expect(both.status == .agentsStopped)

        let (down, _, _) = makeModel(health: { throw URLError(.networkConnectionLost) }, helper: helper)
        await down.refresh()
        #expect(down.status == .unreachable)
    }

    @Test("an answer that says the session ended does not say leverage is unreachable")
    func signedOutIsNotUnreachable() async {
        let (model, _, _) = makeModel(health: { throw ShellFixtures.unauthenticated() })
        await model.refresh()
        #expect(model.status == .checking)
    }

    @Test("Try again asks the helper to start again, then reads the line again")
    func tryAgain() async {
        let helper = FakeAppRuntime().fakeHelper
        helper.current.value = .stoppedTrying
        helper.afterStart.value = .running
        let (model, owner, _) = makeModel(health: { ShellFixtures.health() }, helper: helper)
        await model.refresh()
        #expect(model.offersTryAgain)

        await model.tryAgain()

        #expect(helper.tryAgainCount.value == 1)
        #expect(model.status == .running)
        #expect(owner.calls.count == 2)
    }

    @Test("run reads again on its interval until it is cancelled")
    func runLoop() async {
        let (model, owner, _) = makeModel(health: { ShellFixtures.health() }, interval: .milliseconds(5))
        let task = Task { await model.run() }
        #expect(await ShellFixtures.eventually { owner.calls.count >= 3 })
        task.cancel()
        await task.value
        let settled = owner.calls.count
        try? await Task.sleep(for: .milliseconds(40))
        #expect(owner.calls.count == settled)
    }

    // MARK: the daily backup (HB-4)

    @Test("a backup more than 26 hours old reads The daily backup is late, with the warning tone")
    func backupLate() async {
        let (model, _, _) = makeModel(health: { ShellFixtures.health(backupLate: true) })
        await model.refresh()
        #expect(model.status == .backupLate)
        #expect(model.sentence.text == "The daily backup is late")
        #expect(model.tone == .warning)
        #expect(!model.offersTryAgain)
    }

    @Test("a backup that is on time leaves the line at System is running")
    func backupOnTime() async {
        let (model, _, _) = makeModel(health: { ShellFixtures.health(backupLate: false) })
        await model.refresh()
        #expect(model.status == .running)
    }

    @Test("a late sweep, a helper that gave up and an unreachable server outrank a late backup")
    func backupPrecedence() async {
        let (sweep, _, _) = makeModel(health: { ShellFixtures.health(sweepLate: true, backupLate: true) })
        await sweep.refresh()
        #expect(sweep.status == .late)

        let helper = FakeAppRuntime().fakeHelper
        helper.current.value = .stoppedTrying
        let (gaveUp, _, _) = makeModel(health: { ShellFixtures.health(backupLate: true) }, helper: helper)
        await gaveUp.refresh()
        #expect(gaveUp.status == .agentsStopped)
    }

    @Test("a backup that was made again clears the line")
    func backupRecovers() async {
        let late = Locked(true)
        let (model, _, _) = makeModel(health: { ShellFixtures.health(backupLate: late.value) })
        await model.refresh()
        #expect(model.status == .backupLate)
        late.value = false
        await model.refresh()
        #expect(model.status == .running)
    }

    // MARK: the agent that checks tasks (RD-17, RS-2)

    private func rules(_ rows: [RuleRow]) -> @Sendable () async throws -> RulesList { { RulesList(rules: rows) } }

    private func orchestratorModel(
        _ state: OrchestratorState, rules rows: @escaping @Sendable () async throws -> RulesList,
        sweepLate: Bool = false, backupLate: Bool = false, helper: FakeHelper = FakeAppRuntime().fakeHelper
    ) -> (HealthLineModel, FakeOwnerAPI) {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.systemHealth = { ShellFixtures.health(sweepLate: sweepLate, backupLate: backupLate, orchestrator: state) }
            $0.listRules = rows
        }
        return (HealthLineModel(owner: owner, helper: helper, interval: .milliseconds(5)), owner)
    }

    private var checkerRule: RuleRow { RulesFixtures.row(number: 1, checker: .model, enabled: true) }

    @Test("no agent set up while a rule an agent checks is on says what to do")
    func noOrchestrator() async {
        let (model, owner) = orchestratorModel(.notSetUp, rules: rules([checkerRule]))
        await model.refresh()
        #expect(model.status == .noOrchestrator)
        #expect(model.sentence.text == "No agent is set up to check tasks. Connect one in Agents.")
        #expect(model.tone == .warning)
        #expect(!model.offersTryAgain)
        #expect(owner.calls.map(\.operation) == [.getSystemHealth, .listRules])
    }

    @Test("no agent set up says nothing while every rule an agent checks is off, or does not act yet")
    func noOrchestratorNoRule() async {
        let off = RulesFixtures.row(number: 1, checker: .model, enabled: false)
        let inert = RulesFixtures.row(number: 2, checker: .model, enabled: true, acts: false)
        let app = RulesFixtures.row(number: 3, checker: .app, enabled: true)
        for rows in [[off], [inert], [app], [off, inert, app], []] {
            let (model, _) = orchestratorModel(.notSetUp, rules: rules(rows))
            await model.refresh()
            #expect(model.status == .running, "\(rows.count) rules")
        }
    }

    @Test("a rule list that cannot be read still says no agent is set up, so work is not left waiting without a word")
    func noOrchestratorRulesUnreadable() async {
        let (model, _) = orchestratorModel(.notSetUp, rules: { throw URLError(.timedOut) })
        await model.refresh()
        #expect(model.status == .noOrchestrator)
    }

    @Test("an agent that is online reads System is running and reads no rules")
    func orchestratorOnline() async {
        let (model, owner) = orchestratorModel(.online, rules: rules([checkerRule]))
        await model.refresh()
        #expect(model.status == .running)
        #expect(owner.calls.map(\.operation) == [.getSystemHealth])
    }

    @Test("an agent that is not running reads that, and reads no rules")
    func orchestratorOffline() async {
        let (model, owner) = orchestratorModel(.offline, rules: rules([checkerRule]))
        await model.refresh()
        #expect(model.status == .orchestratorOffline)
        #expect(model.sentence.text == "The agent that checks tasks is not running.")
        #expect(model.tone == .warning)
        #expect(!model.offersTryAgain)
        #expect(owner.calls.map(\.operation) == [.getSystemHealth])
    }

    @Test("a late sweep and a helper that gave up outrank the agent, which outranks a late backup")
    func orchestratorPrecedence() async {
        let (sweep, _) = orchestratorModel(.offline, rules: rules([checkerRule]), sweepLate: true)
        await sweep.refresh()
        #expect(sweep.status == .late)

        let helper = FakeAppRuntime().fakeHelper
        helper.current.value = .stoppedTrying
        let (stopped, _) = orchestratorModel(.offline, rules: rules([checkerRule]), helper: helper)
        await stopped.refresh()
        #expect(stopped.status == .agentsStopped)

        let (backup, _) = orchestratorModel(.offline, rules: rules([checkerRule]), backupLate: true)
        await backup.refresh()
        #expect(backup.status == .orchestratorOffline)

        let (backupNotSetUp, _) = orchestratorModel(.notSetUp, rules: rules([checkerRule]), backupLate: true)
        await backupNotSetUp.refresh()
        #expect(backupNotSetUp.status == .noOrchestrator)
    }

    @Test("the line clears when the agent is online again")
    func orchestratorRecovers() async {
        let state = Locked(OrchestratorState.offline)
        let owner = FakeOwnerAPI()
        owner.script { $0.systemHealth = { ShellFixtures.health(orchestrator: state.value) } }
        let model = HealthLineModel(owner: owner, helper: FakeAppRuntime().fakeHelper, interval: .milliseconds(5))
        await model.refresh()
        #expect(model.status == .orchestratorOffline)
        state.value = .online
        await model.refresh()
        #expect(model.status == .running)
    }
}
