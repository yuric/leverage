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
}
