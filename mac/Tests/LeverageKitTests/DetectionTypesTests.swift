import Foundation
import Testing

@testable import LeverageKit

/// The shared types of detection (plan §2.2, HD-5, HD-7): what a detector is
/// given, what it answers, the words that name a window, and the lookup from
/// a provider to its detector. What each detector answers for each reply
/// file is `DetectorFixtureTests`.
@Suite("Detection types")
struct DetectionTypesTests {
    private let secretText = "standin.owner@example.invalid Stand-in Example Org"

    @Test("a tool run's record never shows its outputs when printed, dumped or interpolated")
    func recordHidesOutputs() {
        let record = ToolRunRecord(
            termination: .exited(1), standardOutput: Data(secretText.utf8),
            standardError: Data("error: \(secretText)".utf8))
        var dumped = ""
        dump(record, to: &dumped)
        for text in [String(describing: record), String(reflecting: record), "\(record)", dumped] {
            #expect(!text.contains("standin.owner"), "\(text)")
            #expect(!text.contains("Example Org"), "\(text)")
        }
        #expect(String(describing: record).contains("exited(1)"))
        #expect(String(describing: record).contains("\(secretText.utf8.count) bytes"))
    }

    @Test("a record is made from a subprocess result, outputs and all")
    func recordFromResult() {
        let result = SubprocessResult(
            termination: .exited(101), standardOutput: Data("out".utf8), standardError: Data("err".utf8),
            endedBy: .timeLimit, outputTruncated: false)
        let record = ToolRunRecord(result)
        #expect(record.termination == .exited(101))
        #expect(record.standardOutput == Data("out".utf8))
        #expect(record.standardError == Data("err".utf8))
        #expect(record.endedBy == .timeLimit)
        #expect(record.outputText == "out")
        #expect(record.errorText == "err")
    }

    @Test("an outcome's name is what a log may say of it, and says nothing of the reply")
    func outcomeNames() {
        #expect(RunOutcome.limit(window: .weekly, resetAt: Date()).name == "limit")
        #expect(RunOutcome.rateLimited.name == "rate_limited")
        #expect(RunOutcome.signedOut.name == "signed_out")
        #expect(RunOutcome.failed.name == "failed")
        #expect(RunOutcome.limit(window: .weekly, resetAt: nil).stopsTheAccount)
        #expect(RunOutcome.signedOut.stopsTheAccount)
        #expect(!RunOutcome.rateLimited.stopsTheAccount)
        #expect(!RunOutcome.failed.stopsTheAccount)
    }

    @Test("a structured field names a window by the contract's word, in any case")
    func windowNamed() {
        #expect(LimitWindowWords.window(named: "five_hour") == .fiveHour)
        #expect(LimitWindowWords.window(named: "WEEKLY") == .weekly)
        #expect(LimitWindowWords.window(named: "per-model") == .perModel)
        #expect(LimitWindowWords.window(named: " spend ") == .spend)
        #expect(LimitWindowWords.window(named: "daily") == nil)
        #expect(LimitWindowWords.window(named: "") == nil)
    }

    @Test("every window has its words, and the contract's own word is among them")
    func everyWindowHasWords() {
        for window in LimitWindow.allCases {
            #expect(LimitWindowWords.words(for: window).contains(window.rawValue), "\(window)")
        }
    }

    @Test("free text names a window only by a whole word", arguments: [
        ("You've reached your 5-hour limit.", [LimitWindow.fiveHour]),
        ("five hour usage limit reached", [.fiveHour]),
        ("Weekly limit reached; per-model limit also reached", [.weekly, .perModel]),
        ("per model limit, then the weekly one", [.perModel, .weekly]),
        ("monthly spend cap reached", [.spend]),
        ("Rate limited. Try again in 5 seconds.", []),
        ("You are spending fast", []),
        ("biweekly report", []),
        ("five_hourly", []),
        ("", []),
    ])
    func windowsInText(text: String, windows: [LimitWindow]) {
        #expect(LimitWindowWords.windows(in: text) == windows)
        #expect(LimitWindowWords.window(in: text) == windows.first)
    }

    @Test("each login provider has its detector; an API token has none")
    func lookup() throws {
        for provider in Provider.allCases {
            let detector = Detectors.detector(for: provider)
            if provider.kind == .login {
                #expect(try #require(detector).provider == provider)
            } else {
                #expect(detector == nil, "\(provider)")
            }
        }
        #expect(Detectors.detector(for: .gemini) is AntigravityDetector)
    }

    @Test("a reply file's basis is spelled as the reply files spell it")
    func basisNames() {
        #expect(ReplyBasis.allCases.map(\.rawValue) == ["recorded_no_login", "invented", "made_from_observed"])
    }
}
