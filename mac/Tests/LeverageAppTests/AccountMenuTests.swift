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

    @Test("a delayed 401 from an old identity read leaves the new session signed in")
    func oldIdentityReadCannotEndNewSession() async throws {
        let rig = ShellRig()
        rig.scriptSignIn(ownerExists: true)
        let started = Locked(false)
        let (release, request) = AsyncStream<Void>.makeStream()
        rig.owner.script {
            $0.ownerIdentity = {
                started.update { $0 = true }
                for await _ in release {}
                throw ShellFixtures.unauthenticated()
            }
        }
        try rig.runtime.sessions.save(ShellFixtures.madeUpSessionToken)
        let model = rig.makeModel()
        await model.launch()
        let previous = try #require(model.screens)
        let read = Task { await previous.loadOwnerIdentity() }
        defer { request.finish() }
        try #require(await ShellFixtures.eventually { started.value })

        await model.signOut()
        let signIn = try #require(model.signIn)
        signIn.email = ShellFixtures.madeUpEmail
        signIn.password = ShellFixtures.madeUpPassword
        await signIn.submit()
        let current = try #require(model.screens)

        request.finish()
        await read.value
        #expect(model.screens === current)
        #expect(model.isSignedIn)
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
