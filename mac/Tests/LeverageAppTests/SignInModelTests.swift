import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("SignInModel")
struct SignInModelTests {
    private func makeModel(
        _ mode: SignInModel.Mode, owner: FakeOwnerAPI, tokens: Locked<[String]> = Locked([])
    ) -> SignInModel {
        let model = SignInModel(mode: mode, api: owner, onSignedIn: { token in tokens.update { $0.append(token) } })
        model.email = ShellFixtures.madeUpEmail
        model.password = ShellFixtures.madeUpPassword
        return model
    }

    private func scripted(
        create: (@Sendable (SignInRequest, IdempotencyKey) async throws -> CommandOutcome<OwnerSessionAnswer>)? = nil,
        signIn: (@Sendable (SignInRequest, IdempotencyKey) async throws -> CommandOutcome<OwnerSessionAnswer>)? = nil
    ) -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        owner.script {
            $0.createOwner = create ?? { _, key in ShellFixtures.sessionAnswer(key: key.value, command: .createOwner) }
            $0.signIn = signIn ?? { _, key in ShellFixtures.sessionAnswer(key: key.value, command: .signIn) }
        }
        return owner
    }

    @Test("creating the sign-in sends create_owner with the email address and password, then hands over the token")
    func create() async {
        let owner = scripted()
        let tokens = Locked<[String]>([])
        let model = makeModel(.create, owner: owner, tokens: tokens)

        await model.submit()

        #expect(owner.calls.map(\.operation) == [.createOwner])
        #expect(owner.calls.first?.body == .object([
            "email_address": .string(ShellFixtures.madeUpEmail),
            "password": .string(ShellFixtures.madeUpPassword),
        ]))
        #expect(owner.calls.first?.key != nil)
        #expect(tokens.value == [ShellFixtures.madeUpSessionToken])
        #expect(model.state == .signedIn)
    }

    @Test("signing in sends sign_in_owner and not create_owner")
    func signIn() async {
        let owner = scripted()
        let tokens = Locked<[String]>([])
        let model = makeModel(.signIn, owner: owner, tokens: tokens)

        await model.submit()

        #expect(owner.calls.map(\.operation) == [.signInOwner])
        #expect(tokens.value == [ShellFixtures.madeUpSessionToken])
    }

    @Test("the email address is sent without the spaces around it")
    func trimsEmail() async {
        let owner = scripted()
        let model = makeModel(.signIn, owner: owner)
        model.email = "  \(ShellFixtures.madeUpEmail)\n"

        await model.submit()

        #expect(owner.calls.first?.body?["email_address"] == .string(ShellFixtures.madeUpEmail))
    }

    @Test("nothing is sent until there is an email address and a password; a new password needs 8 characters")
    func validation() async {
        let owner = scripted()
        let model = makeModel(.create, owner: owner)

        model.email = ""
        #expect(!model.canSubmit)
        model.email = "no-at-sign"
        #expect(!model.canSubmit)
        model.email = ShellFixtures.madeUpEmail
        model.password = "short"
        #expect(!model.canSubmit)
        await model.submit()
        #expect(owner.calls.isEmpty)
        #expect(model.state == .idle)

        model.password = "long-enough"
        #expect(model.canSubmit)

        // Signing in asks only that something is typed (IN-4 is about a new password).
        let signIn = makeModel(.signIn, owner: owner)
        signIn.password = "short"
        #expect(signIn.canSubmit)
        signIn.password = ""
        #expect(!signIn.canSubmit)
    }

    @Test("a wrong password says the details do not match and keeps what was typed")
    func wrongPassword() async {
        let owner = scripted(signIn: { _, _ in throw ShellFixtures.unauthenticated() })
        let tokens = Locked<[String]>([])
        let model = makeModel(.signIn, owner: owner, tokens: tokens)

        await model.submit()

        #expect(model.state == .failed(.wrongDetails))
        #expect(tokens.value.isEmpty)
        #expect(model.email == ShellFixtures.madeUpEmail)
    }

    @Test("when leverage cannot be reached, trying again sends the same command with the same key")
    func retryKeepsKey() async {
        let attempts = Locked(0)
        let owner = scripted(signIn: { _, key in
            if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.cannotConnectToHost) }
            return ShellFixtures.sessionAnswer(key: key.value, command: .signIn)
        })
        let tokens = Locked<[String]>([])
        let model = makeModel(.signIn, owner: owner, tokens: tokens)

        await model.submit()
        #expect(model.state == .failed(.cannotReach))
        await model.submit()

        #expect(owner.calls.count == 2)
        #expect(owner.calls[0].key == owner.calls[1].key)
        #expect(owner.calls[0].body == owner.calls[1].body)
        #expect(tokens.value == [ShellFixtures.madeUpSessionToken])
    }

    @Test("changing what was typed takes a new key, so the server never sees one key with two bodies")
    func changedFieldsTakeNewKey() async {
        let owner = scripted(signIn: { _, _ in throw URLError(.timedOut) })
        let model = makeModel(.signIn, owner: owner)

        await model.submit()
        model.password = "another-made-up-password"
        await model.submit()
        await model.submit()

        #expect(owner.calls.count == 3)
        #expect(owner.calls[0].key != owner.calls[1].key)
        #expect(owner.calls[1].key == owner.calls[2].key)
    }

    @Test("a repeat that answers without a token is sent again with a new key (IN-9)")
    func repeatedAnswerSignsInAgain() async {
        let attempts = Locked(0)
        let owner = scripted(signIn: { _, key in
            if attempts.update({ $0 += 1; return $0 }) == 1 {
                return ShellFixtures.repeatedAnswer(key: key.value, command: .signIn)
            }
            return ShellFixtures.sessionAnswer(key: key.value, command: .signIn)
        })
        let tokens = Locked<[String]>([])
        let model = makeModel(.signIn, owner: owner, tokens: tokens)

        await model.submit()

        #expect(owner.calls.count == 2)
        #expect(owner.calls[0].key != owner.calls[1].key)
        #expect(tokens.value == [ShellFixtures.madeUpSessionToken])
        #expect(model.state == .signedIn)
    }

    @Test("creating a second sign-in is refused with not found: the screen turns into Sign in")
    func alreadyCreated() async {
        let owner = scripted(create: { _, _ in throw TransportError(code: .notFound, message: "No.") })
        let model = makeModel(.create, owner: owner)

        await model.submit()

        #expect(model.state == .failed(.alreadyCreated))
        #expect(model.mode == .signIn)
    }

    @Test("details the server refuses as invalid are said in one plain line")
    func invalidDetails() async {
        let owner = scripted(create: { _, _ in throw TransportError(code: .invalid, message: "Too short.") })
        let model = makeModel(.create, owner: owner)

        await model.submit()

        #expect(model.state == .failed(.invalidDetails))
    }

    @Test("a refused command and an unreadable answer end in the general line")
    func otherFailures() async {
        let refused = scripted(signIn: { _, key in
            .refused(Refusal(code: .invalidState, ruleID: nil, reason: "never shown"), key: key.value, command: .signIn)
        })
        let model = makeModel(.signIn, owner: refused)
        await model.submit()
        #expect(model.state == .failed(.somethingWentWrong))

        let unreadable = scripted(signIn: { _, _ in throw LeverageClientError.invalidBody })
        let second = makeModel(.signIn, owner: unreadable)
        await second.submit()
        #expect(second.state == .failed(.somethingWentWrong))
    }

    @Test("while a request is out the button is off, and a second press sends nothing")
    func busy() async {
        let release = Locked(false)
        let owner = scripted(signIn: { _, key in
            while !release.value { try await Task.sleep(for: .milliseconds(2)) }
            return ShellFixtures.sessionAnswer(key: key.value, command: .signIn)
        })
        let model = makeModel(.signIn, owner: owner)

        let first = Task { await model.submit() }
        #expect(await ShellFixtures.eventually { model.state == .busy && owner.calls.count == 1 })
        #expect(!model.canSubmit)
        await model.submit()
        #expect(owner.calls.count == 1)

        release.value = true
        await first.value
        #expect(model.state == .signedIn)
    }
}
