import AppKit
import Foundation
import LeverageKit
import LeverageTestSupport
import SwiftUI
import Testing

@testable import LeverageApp

private typealias Fixtures = AgentFixtures

/// The setup assistant's screens in the states the owner meets them in,
/// shared by the render smoke test.
@MainActor
enum SetupAssistantScenes {
    static func all() async -> [(name: String, model: SetupAssistantModel)] {
        var scenes: [(String, SetupAssistantModel)] = []

        scenes.append(("welcome", await AssistantRig.make().model))

        let first = await AssistantRig.make().model
        first.next()
        scenes.append(("first-login", first))

        let picked = await AssistantRig.make().model
        picked.next()
        picked.pick(.claude)
        picked.attempt?.name = "Personal"
        scenes.append(("first-login-name", picked))

        let checking = await AssistantRig.make()
        checking.owner.script {
            $0.addCredential = { body, key in
                .completed(AddCredentialResult(credentialID: body.credentialID, helperRequestID: UUID()), key: key.value,
                           command: .addCredential)
            }
            $0.helperRequest = { id, _, _ in
                Fixtures.request(
                    id, state: .failed,
                    progress: [
                        Fixtures.progress(.toolInstalled, .passed),
                        Fixtures.progress(.signedIn, .failed, failure: .notSignedIn),
                    ],
                    result: Fixtures.finished(
                        .failed, failing: [HelperCheckResult(check: .signedIn, passed: false, failure: .notSignedIn)]),
                    updated: 3)
            }
        }
        checking.model.next()
        checking.model.pick(.claude)
        checking.model.attempt?.name = "Personal"
        await checking.model.signIn()
        scenes.append(("first-login-failed", checking.model))

        let second = await AssistantRig.make(credentials: SetupFixtures.oneLogin, choice: .started).model
        second.toggleOneSubscription()
        scenes.append(("second-login-one", second))

        scenes.append(("agents", await AssistantRig.twoLogins().model))

        let started = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started).model
        started.back()
        scenes.append(("agents-started", started))

        let task = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started).model
        task.choose(.todo)
        scenes.append(("first-task", task))

        let own = await AssistantRig.make(
            credentials: SetupFixtures.twoLogins, seats: SetupFixtures.twoAgents, choice: .started).model
        own.toggleWriteOwn()
        own.ownTitle = "Fix the totals"
        scenes.append(("first-task-own", own))
        return scenes
    }

    /// The screen on the window's backdrop, or alone, so a test can tell
    /// that the screen itself drew something.
    static func view(_ model: SetupAssistantModel, dark: Bool, backdrop: Bool = false) -> some View {
        ZStack {
            if backdrop { Backdrop() }
            SetupAssistantContent(model: model)
        }
        .foregroundStyle(Tokens.Palette.text)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@MainActor
@Suite("Setup assistant render smoke")
struct SetupAssistantRenderTests {
    @Test("every screen of the assistant draws, light and dark")
    func screensDraw() async {
        let scenes = await SetupAssistantScenes.all()
        #expect(scenes.count == 9)
        for (name, model) in scenes {
            for dark in [false, true] {
                #expect(
                    Fixtures.draws(SetupAssistantScenes.view(model, dark: dark), width: 1000, height: 720),
                    "\(name) \(dark ? "dark" : "light")")
            }
        }
    }

    @Test("the assistant draws from the shell's context")
    func drawsFromContext() {
        let rig = ShellRig()
        let context = ScreenContext(
            owner: rig.owner, feed: EventFeed(owner: rig.owner),
            health: HealthLineModel(owner: rig.owner, helper: rig.runtime.helper), runtime: rig.runtime)
        #expect(Fixtures.draws(SetupAssistantView().environment(context), width: 1000, height: 720))
    }
}
