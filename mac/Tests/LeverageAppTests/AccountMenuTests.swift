import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Account menu")
struct AccountMenuTests {
    @Test("a kept session reads the owner's email once and clears it at sign out")
    func readsIdentityInKeptSession() async throws {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let calls = Locked(0)
        rig.owner.script {
            $0.ownerIdentity = {
                calls.update { $0 += 1 }
                return OwnerSessionIdentity(emailAddress: ShellFixtures.madeUpEmail, asOfSeq: 12)
            }
        }
        try rig.runtime.sessions.save(ShellFixtures.madeUpSessionToken)
        let model = rig.makeModel()
        await model.launch()
        let context = try #require(model.screens)

        await context.loadOwnerIdentity()
        await context.loadOwnerIdentity()
        #expect(context.ownerEmail == ShellFixtures.madeUpEmail)
        #expect(calls.value == 1)

        await model.signOut()
        #expect(model.screens == nil)
        #expect(try rig.runtime.sessions.load() == nil)
    }

    @Test("opening the menu can retry a failed identity read")
    func retriesIdentity() async throws {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let calls = Locked(0)
        rig.owner.script {
            $0.ownerIdentity = {
                calls.update { $0 += 1 }
                if calls.value == 1 { throw URLError(.notConnectedToInternet) }
                return OwnerSessionIdentity(emailAddress: ShellFixtures.madeUpEmail, asOfSeq: 12)
            }
        }
        try rig.runtime.sessions.save(ShellFixtures.madeUpSessionToken)
        let model = rig.makeModel()
        await model.launch()
        let context = try #require(model.screens)

        await context.loadOwnerIdentity()
        #expect(context.ownerEmail == nil)
        #expect(model.isSignedIn)
        await context.loadOwnerIdentity()
        #expect(context.ownerEmail == ShellFixtures.madeUpEmail)
    }

    @Test("the identity read observes a server-ended session")
    func respectsSessionExpiry() async throws {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        rig.owner.script {
            $0.ownerIdentity = { throw ShellFixtures.unauthenticated() }
        }
        try rig.runtime.sessions.save(ShellFixtures.madeUpSessionToken)
        let model = rig.makeModel()
        await model.launch()
        let context = try #require(model.screens)

        await context.loadOwnerIdentity()
        #expect(model.phase == .signIn)
        #expect(model.screens == nil)
        #expect(try rig.runtime.sessions.load() == nil)
    }
}
