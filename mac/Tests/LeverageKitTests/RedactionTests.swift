import Foundation
import Testing

@testable import LeverageKit

/// What is removed before the Mac side writes a line (plan CL-29, IN-18).
/// Every value here is made up.
@Suite("Redaction")
struct RedactionTests {
    @Test("a token of each kind is removed by its prefix, wherever it is", arguments: [
        ("seat lvs_Q2hhbmdlTWUtTWFkZVVwVG9rZW4tVmFsdWUtMDAx ended", "seat lvs_[removed] ended"),
        ("helper=lvh_bWFkZS11cA_-xyz0123456789ABCDEFGHIJKL.", "helper=lvh_[removed]."),
        ("\"token\":\"lvo_c2Vzc2lvbi1tYWRlLXVw\"", "\"token\":\"lvo_[removed]\""),
    ])
    func tokens(line: String, expected: String) {
        #expect(Redaction.redact(line) == expected)
    }

    @Test("an email address is removed")
    func email() {
        #expect(Redaction.redact("signed in as standin.owner@example.invalid (Org)")
            == "signed in as [email removed] (Org)")
    }

    @Test("a bearer header's value is removed, whatever its shape")
    func bearer() {
        #expect(Redaction.redact("Authorization: Bearer abc.DEF-123/xyz") == "Authorization: Bearer [removed]")
        #expect(Redaction.redact("authorization: bearer opaque") == "authorization: bearer [removed]")
    }

    @Test("a value the caller names is removed too")
    func namedSecrets() {
        #expect(Redaction.redact("password is made-up-pass-1 here", removing: ["made-up-pass-1"])
            == "password is [removed] here")
        #expect(Redaction.redact("nothing", removing: [""]) == "nothing")
    }

    @Test("ordinary text is left as it is")
    func ordinaryText() {
        let line = "run of seat 0b4e started; lvs_ alone is not a token; 2 + 2 = 4"
        #expect(Redaction.redact(line) == line)
    }

    @Test("provider key prefixes redact key-shaped values and preserve short words")
    func providerKeys() {
        for prefix in ["sk-", "xai-", "AIza"] {
            let key = prefix + "LVRG-TOKEN-000000000001"
            let wasRemoved = Redaction.redact("value=\"\(key)\"") == "value=\"[removed]\""
            let minimumLength = prefix + String(repeating: "Z", count: 16)
            let minimumWasRemoved = Redaction.redact(minimumLength) == "[removed]"
            let tooShort = String(minimumLength.dropLast())
            let shortWasKept = Redaction.redact(tooShort) == tooShort
            #expect(wasRemoved, "\(prefix)")
            #expect(minimumWasRemoved, "\(prefix)")
            #expect(shortWasKept, "\(prefix)")
        }
        #expect(Redaction.redact("sk-learn is a package") == "sk-learn is a package")
    }
}

@Suite("Log")
struct LogTests {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    @Test("a line has the time, the component, the level and the redacted message")
    func lineShape() {
        let lines = Lines()
        let log = Log(
            component: "helper",
            write: { lines.append($0) },
            now: { Date(timeIntervalSince1970: 1_800_000_000) })

        log.info("started run with lvs_bWFkZS11cC1tYWRlLXVwLW1hZGUtdXA for owner@example.invalid")
        log.error("failed")

        #expect(lines.all == [
            "2027-01-15T08:00:00Z helper info: started run with lvs_[removed] for [email removed]\n",
            "2027-01-15T08:00:00Z helper error: failed\n",
        ])
    }

    @Test("a message spread over several lines stays one line")
    func oneLine() {
        let lines = Lines()
        let log = Log(component: "runner", write: { lines.append($0) }, now: { Date(timeIntervalSince1970: 0) })
        log.warning("first\nsecond\r\nthird")
        #expect(lines.all == ["1970-01-01T00:00:00Z runner warning: first second third\n"])
    }
}
