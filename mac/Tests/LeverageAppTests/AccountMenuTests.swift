import AppKit
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

/// The menu itself (FR-002 to FR-004): its items, the disabled Subscription
/// entry, the ⌘ , shortcut, and what each choice runs. Popping it up and
/// moving through it with the keyboard need a person.
@MainActor
@Suite("Account menu items")
struct AccountMenuItemsTests {
    @Test("the menu lists the email, then Subscription (not yet available), Settings ⌘ , and Sign out")
    func items() {
        let menu = AccountMenuAnchor().makeMenu(title: ShellFixtures.madeUpEmail)
        #expect(menu.items.map(\.title) == [
            ShellFixtures.madeUpEmail, ShellCopy.subscription.text, ShellCopy.settings.text, "",
            ShellCopy.signOut.text,
        ])
        #expect(menu.items[0].isSectionHeader)
        #expect(menu.items[3].isSeparatorItem)
        #expect(!menu.autoenablesItems)
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[1].action == nil)
        #expect(menu.items[2].isEnabled)
        #expect(menu.items[2].keyEquivalent == ",")
        #expect(menu.items[2].keyEquivalentModifierMask == .command)
        #expect(menu.items[4].isEnabled)
        #expect(menu.items[4].keyEquivalent.isEmpty)
    }

    @Test("choosing Settings or Sign out records that choice")
    func choosing() {
        _ = NSApplication.shared
        let anchor = AccountMenuAnchor()
        let menu = anchor.makeMenu(title: ShellFixtures.madeUpEmail)
        #expect(anchor.choice == nil)
        menu.performActionForItem(at: 2)
        #expect(anchor.choice == .settings)
        menu.performActionForItem(at: 4)
        #expect(anchor.choice == .signOut)
    }

    @Test("a choice runs its action: Settings opens Settings, Sign out signs out, and none runs nothing")
    func perform() async {
        let opened = Locked(0)
        let signedOut = Locked(0)
        func run(_ choice: AccountMenuAnchor.Choice?) async {
            await AccountMenu.perform(
                choice, openSettings: { opened.update { $0 += 1 } }, signOut: { signedOut.update { $0 += 1 } })?.value
        }
        await run(nil)
        #expect(opened.value == 0 && signedOut.value == 0)
        await run(.settings)
        #expect(opened.value == 1 && signedOut.value == 0)
        await run(.signOut)
        #expect(opened.value == 1 && signedOut.value == 1)
    }

    @Test("the row's VoiceOver label names what the menu holds (FR-003)")
    func voiceOverLabel() {
        #expect(ShellCopy.accountMenu.text == "Subscription, settings and sign out")
    }
}
