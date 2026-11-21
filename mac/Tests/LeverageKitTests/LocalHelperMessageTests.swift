import Foundation
import Testing

@testable import LeverageKit

@Suite("Local helper message")
struct LocalHelperMessageTests {
    private let credentialID = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    private let madeUpToken = "sk-LVRG-TOKEN-000000000001-for-tests"

    @Test("version 2 token and version 1 forget messages each encode as one JSON object and decode")
    func roundTrips() throws {
        let token = madeUpToken + "\"\\\n\r"
        let grantLine = try LocalHelperMessage.token(credentialID: credentialID, provider: .openrouter, token: token).encodeLine()
        let forgetLine = try LocalHelperMessage.forget(credentialID: credentialID).encodeLine()

        let grantWireFormatMatches = matchesWireFormat(grantLine, kind: "token", token: token)
        #expect(grantWireFormatMatches)
        #expect(matchesWireFormat(forgetLine, kind: "forget", token: nil))
        let grantMatches: Bool
        if case .token(let id, let provider, let decodedToken) = try LocalHelperMessage.decodeLine(grantLine) {
            grantMatches = id == credentialID && provider == .openrouter && decodedToken == token
        } else {
            grantMatches = false
        }
        #expect(grantMatches)
        guard case .forget(let id) = try LocalHelperMessage.decodeLine(forgetLine) else {
            Issue.record("the forget line returned the wrong message kind")
            return
        }
        #expect(id == credentialID)
    }

    private func matchesWireFormat(_ line: Data, kind: String, token: String?) -> Bool {
        guard !line.contains(0x0A), !line.contains(0x0D),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return false
        }
        let fields = token == nil ? ["version", "kind", "credential_id"] : ["version", "kind", "credential_id", "provider", "token"]
        return Set(object.keys) == Set(fields) && object["version"] as? Int == (token == nil ? 1 : 2)
            && object["kind"] as? String == kind
            && (object["credential_id"] as? String).flatMap(UUID.init(uuidString:)) == credentialID
            && object["provider"] as? String == (token == nil ? nil : "openrouter")
            && object["token"] as? String == token
    }

    @Test("unknown kinds, wrong versions, missing fields and invalid JSON are refused")
    func invalidLines() throws {
        let lines = [
            #"{"version":1,"kind":"other","credential_id":"\#(credentialID)"}"#,
            #"{"version":2,"kind":"forget","credential_id":"\#(credentialID)"}"#,
            #"{"version":1,"kind":"token","credential_id":"\#(credentialID)"}"#,
            #"{"version":1,"kind":"forget"}"#,
            #"{"version":1,"kind":"forget","credential_id":"made-up-id"}"#,
            #"{"kind":"forget","credential_id":"\#(credentialID)"}"#,
            #"{"version":1,"credential_id":"\#(credentialID)"}"#,
            #"{"version":"1","kind":"forget","credential_id":"\#(credentialID)"}"#,
            #"{"version":1,"kind":"token","credential_id":"\#(credentialID)","token":false}"#,
            #"{"version":1,"kind":"token","credential_id":"\#(credentialID)","token":"\#(madeUpToken)"}"#,
            #"{"version":1,"kind":"token","credential_id":"\#(credentialID)","token":"\#(madeUpToken)","provider":"openrouter"}"#,
            #"{"version":2,"kind":"token","credential_id":"\#(credentialID)","token":"\#(madeUpToken)"}"#,
            #"{"version":2,"kind":"token","credential_id":"\#(credentialID)","token":"\#(madeUpToken)","provider":"codex"}"#,
            "not JSON",
        ]
        for line in lines {
            let refused = refuses(Data(line.utf8))
            #expect(refused)
        }
        let valid = try LocalHelperMessage.forget(credentialID: credentialID).encodeLine()
        #expect(refuses(valid + Data([0x0A])))
        #expect(refuses(valid + Data([0x0D])))
        #expect(refuses(valid + Data([0x0A]) + valid))
    }

    private func refuses(_ line: Data) -> Bool {
        do {
            _ = try LocalHelperMessage.decodeLine(line)
            return false
        } catch {
            return error as? LocalHelperMessage.CodingError == .invalidLine
        }
    }

    @Test("descriptions, dumps and reflection show the kind and id and remove the token")
    func safelyPrintable() {
        let message = LocalHelperMessage.token(credentialID: credentialID, provider: .openrouter, token: madeUpToken)
        var dumped = ""
        dump(message, to: &dumped)
        let children = Mirror(reflecting: message).children.map { String(reflecting: $0.value) }
        let rendered = [String(describing: message), String(reflecting: message), dumped, children.joined(separator: " ")]
        let everyFormIsSafe = rendered.allSatisfy {
            $0.contains(credentialID.uuidString) && $0.contains("token") && !$0.contains(madeUpToken)
        }
        #expect(everyFormIsSafe)
    }

    @Test("every token has the same eight-dot label")
    func fixedMask() {
        let inputs = ["", madeUpToken, "•• abc 🔒"]
        for input in inputs {
            let isFixed = MaskedLabel.forToken(input) == "••••••••"
            #expect(isFixed)
        }
    }

    @Test("the credentials environment names are spelled as the helper expects")
    func environmentNames() {
        #expect(EnvironmentKeys.tokenStore == "LEVERAGE_TOKEN_STORE")
        #expect(EnvironmentKeys.providerAPIBase == "LEVERAGE_PROVIDER_API_BASE")
        #expect(EnvironmentKeys.readTimeoutSeconds == "LEVERAGE_READ_TIMEOUT_SECONDS")
    }
}
