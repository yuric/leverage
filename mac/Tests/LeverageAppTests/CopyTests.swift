import Foundation
import LeverageKit
import Testing

@testable import LeverageApp

/// The ten terms of the PRD's plain-language rule (L792): a word on an
/// owner-facing screen that a person stops at is a defect, and these ten are
/// the starting list.
enum BannedTerms {
    static let pattern =
        #"\b(?:hooks?|leases?|leased|rule versions?|pending transitions?|seats?|holds?|rounds?|strength ranks?|overrides?|imaginarium)\b"#

    /// The banned terms `text` uses, lower case.
    static func found(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        }
    }
}

/// Finds a string literal written straight into a view or a label, which
/// would put an owner-facing sentence outside the copy catalogs.
enum LiteralScanner {
    /// `source` with its comments removed and the inside of every string
    /// literal emptied (`"abc"` becomes `""`), so a pattern search sees code only.
    static func code(of source: String) -> String {
        let chars = Array(source)
        var out = ""
        var i = 0
        func peek(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
        while i < chars.count {
            let c = chars[i]
            if c == "/", peek(1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", peek(1) == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && peek(1) == "/") { i += 1 }
                i += 2
            } else if c == "\"" {
                let multiline = peek(1) == "\"" && peek(2) == "\""
                i += multiline ? 3 : 1
                out += "\"\""
                while i < chars.count {
                    if chars[i] == "\\" {
                        if peek(1) == "(" {
                            var depth = 0
                            i += 1
                            while i < chars.count {
                                if chars[i] == "(" { depth += 1 }
                                if chars[i] == ")" { depth -= 1; if depth == 0 { i += 1; break } }
                                i += 1
                            }
                        } else {
                            i += 2
                        }
                    } else if multiline, chars[i] == "\"", peek(1) == "\"", peek(2) == "\"" {
                        i += 3
                        break
                    } else if !multiline, chars[i] == "\"" {
                        i += 1
                        break
                    } else {
                        i += 1
                    }
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    static let calls = [
        "Text", "Button", "Label", "TextField", "SecureField", "Toggle", "Picker", "Section", "Menu", "GroupBox",
        "LabeledContent", "Window", "navigationTitle", "help", "accessibilityLabel", "accessibilityHint",
        "accessibilityValue", "alert", "confirmationDialog", "ProgressView",
    ]

    /// The calls in `source` that are given a string literal as their first argument.
    static func offenders(in source: String) -> [String] {
        let pattern = #"\b(\#(calls.joined(separator: "|")))\(\s*""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = code(of: source)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

@Suite("Copy")
struct CopyTests {
    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/LeverageApp")

    private static func swiftFiles() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: keys) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    // MARK: the scanners test themselves first, so a green run means something

    @Test("the banned-term scanner finds each of the ten terms, as whole words only")
    func bannedScannerWorks() {
        for term in [
            "hook", "lease", "rule version", "pending transition", "seat", "hold", "round", "strength rank", "override",
            "Imaginarium",
        ] {
            #expect(BannedTerms.found(in: "A sentence with the \(term) in it.") == [term.lowercased()], "\(term)")
        }
        #expect(BannedTerms.found(in: "The seats were leased and the rounds were held by the overrides.") ==
            ["seats", "leased", "rounds", "overrides"])
        #expect(BannedTerms.found(in: "Around the household, a thorough ground check, a hooked fish.").isEmpty)
    }

    @Test("the literal scanner flags a string passed straight to a view, and nothing else")
    func literalScannerWorks() {
        #expect(LiteralScanner.offenders(in: #"Text("Hello")"#) == ["Text"])
        #expect(LiteralScanner.offenders(in: "Button(\n  \"Go\") { }") == ["Button"])
        #expect(LiteralScanner.offenders(in: #"Label("Go", systemImage: "x")"#) == ["Label"])
        #expect(LiteralScanner.offenders(in: #"TextField("Name", text: $name)"#) == ["TextField"])
        #expect(LiteralScanner.offenders(in: #"x.navigationTitle("T")"#) == ["navigationTitle"])
        #expect(LiteralScanner.offenders(in: #"Text("\(count) tasks")"#) == ["Text"])

        #expect(LiteralScanner.offenders(in: "Text(ShellCopy.signOut.text)").isEmpty)
        #expect(LiteralScanner.offenders(in: "Button(model.title) { }").isEmpty)
        #expect(LiteralScanner.offenders(in: #"// Text("in a comment")"#).isEmpty)
        #expect(LiteralScanner.offenders(in: "/* Text(\"in a block\") */ let x = 1").isEmpty)
        #expect(LiteralScanner.offenders(in: #"let note = "Text(\"inside a string\")""#).isEmpty)
        #expect(LiteralScanner.offenders(in: #"Text(verbatim: model.name)"#).isEmpty)
        #expect(LiteralScanner.offenders(in: #"let url = "http://example.invalid"; Text(a.b)"#).isEmpty)
    }

    // MARK: the catalogs

    @Test("the source folder was found and has the screens' folders in it")
    func sourcesFound() {
        let names = Set(Self.swiftFiles().map(\.lastPathComponent))
        for expected in [
            "Copy.swift", "ShellCopy.swift", "SignInCopy.swift", "BoardCopy.swift", "AddTaskCopy.swift",
            "TaskPageCopy.swift", "AgentsCopy.swift", "CredentialsCopy.swift", "NeedsYouCopy.swift", "HandoffCopy.swift",
            "RulesCopy.swift", "RootView.swift", "AppModel.swift",
        ] {
            #expect(names.contains(expected), "\(expected)")
        }
    }

    @Test("CopyCatalogs.all lists every enum in the app that is a copy catalog, once")
    func listIsComplete() throws {
        let regex = try NSRegularExpression(pattern: #"\benum\s+(\w+)\s*:\s*[^{]*\bOwnerFacingCopy\b"#)
        var declared: [String] = []
        for file in Self.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = LiteralScanner.code(of: source)
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                if let name = Range(match.range(at: 1), in: code).map({ String(code[$0]) }) { declared.append(name) }
            }
        }
        let listed = CopyCatalogs.all.map { String(describing: $0) }
        #expect(Set(declared) == Set(listed))
        #expect(Set(listed).count == listed.count)
        #expect(declared.count >= 7)
    }

    @Test("every sentence of every catalog is filled in, trimmed, and on one line")
    func sentencesAreTidy() {
        for catalog in CopyCatalogs.all {
            for text in catalog.allTexts {
                #expect(!text.isEmpty, "\(catalog)")
                #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines), "\(catalog): \(text)")
                #expect(!text.contains("  "), "\(catalog): \(text)")
                #expect(!text.contains("\n"), "\(catalog): \(text)")
            }
        }
    }

    @Test("no sentence of any catalog uses one of the ten banned terms (L792)")
    func noBannedTerms() {
        for catalog in CopyCatalogs.all {
            for text in catalog.allTexts {
                #expect(BannedTerms.found(in: text).isEmpty, "\(catalog): \(text)")
            }
        }
    }

    @Test("no sentence states how many times a task was sent back: the limit is a setting and can be raised")
    func noFixedCounts() {
        for catalog in CopyCatalogs.all {
            for text in catalog.allTexts {
                #expect(text.range(of: #"\b\d+ times\b"#, options: .regularExpression) == nil, "\(catalog): \(text)")
            }
        }
    }

    @Test("no source file passes a string literal straight to a view, a label or a field")
    func noLiteralsInViews() throws {
        let files = Self.swiftFiles()
        #expect(files.count >= 15)
        for file in files {
            let found = LiteralScanner.offenders(in: try String(contentsOf: file, encoding: .utf8))
            #expect(found.isEmpty, "\(file.lastPathComponent): \(found)")
        }
    }

    // MARK: sentences for refusals and transport errors (MA-19)

    @Test("every refusal code has its own plain sentence")
    func refusalSentences() {
        let sentences = RefusalCode.allCases.map { ShellCopy.refusal($0).text }
        #expect(sentences.count == RefusalCode.allCases.count)
        #expect(Set(sentences).count == sentences.count)
        for code in RefusalCode.allCases {
            let text = ShellCopy.refusal(code).text
            #expect(!text.contains(code.rawValue), "\(code): \(text)")
            #expect(!text.contains("_"), "\(code): \(text)")
        }
    }

    @Test("every transport error has its own plain sentence")
    func transportSentences() {
        let sentences = TransportErrorCode.allCases.map { ShellCopy.transport($0).text }
        #expect(Set(sentences).count == sentences.count)
        #expect(ShellCopy.transport(.unauthenticated).text == "Your sign-in ended. Sign in again.")
    }

    @Test("a thrown error becomes a sentence: refusals and transport errors by code, anything else by its kind")
    func errorSentences() {
        let refusal = Refusal(code: .duplicateName, ruleID: nil, reason: "never shown to the owner")
        #expect(ShellCopy.sentence(for: LeverageClientError.refused(refusal)) == ShellCopy.refusal(.duplicateName))
        #expect(ShellCopy.sentence(for: TransportError(code: .notFound, message: "x")) == ShellCopy.transport(.notFound))
        #expect(ShellCopy.sentence(for: URLError(.cannotConnectToHost)) == .cannotReach)
        #expect(ShellCopy.sentence(for: URLError(.timedOut)) == .cannotReach)
        #expect(ShellCopy.sentence(for: LeverageClientError.invalidBody) == .somethingWentWrong)
        #expect(ShellCopy.sentence(for: LeverageClientError.unexpectedStatus(500)) == .somethingWentWrong)
        #expect(ShellCopy.sentence(for: CancellationError()) == .somethingWentWrong)
    }

    @Test("the health line sentences are the ones MA-23 names")
    func healthSentences() {
        #expect(ShellCopy.healthRunning.text == "System is running")
        #expect(ShellCopy.healthLate.text == "Background work is late")
        #expect(ShellCopy.healthAgentsStopped.text == "Agents are not running on this Mac")
        #expect(ShellCopy.healthUnreachable.text == "Can't reach leverage on this Mac")
    }

    @Test("the start-up sentences are the ones PK-3 names")
    func startupSentences() {
        #expect(ShellCopy.dockerMissingTitle.text == "leverage needs Docker Desktop")
        #expect(ShellCopy.getDockerDesktop.text == "Get Docker Desktop")
        #expect(ShellCopy.checkAgain.text == "Check again")
        #expect(ShellCopy.dockerStartingTitle.text == "Starting Docker Desktop")
        #expect(ShellCopy.imageMissingTitle.text == "This copy of leverage was not built on this Mac.")
    }

    @Test("sign-in sentences follow IN-2 and the mockup's wording")
    func signInSentences() {
        #expect(SignInCopy.createTitle.text == "Create your sign-in")
        #expect(SignInCopy.signInTitle.text == "Sign in")
    }

    // MARK: the Needs you sentences (HM-24, HM-28, HM-29)

    @Test("the Needs you sentences are the ones HM-24 names")
    func needsYouSentences() {
        #expect(NeedsYouCopy.empty.text == "Nothing needs you right now.")
        #expect(NeedsYouCopy.signedOutHeading.text == "{account} is signed out")
        #expect(
            NeedsYouCopy.signedOutBody.text
                == "{task} stopped because {account} is signed out and no other account can take over. Sign in again to continue.")
        #expect(NeedsYouCopy.signInAgain.text == "Sign in again")
        #expect(NeedsYouCopy.signInWaiting.text == "Waiting for you to sign in in the window that opened")
        #expect(NeedsYouCopy.limitHeading.text == "{account} is at its limit")
        #expect(
            NeedsYouCopy.limitBody.text
                == "{task} is waiting. {provider} did not say when {account} is available again. When it is, choose Verify on {account} in Credentials and the task continues. If the agent's time on the task runs out first, the task goes back to waiting for any agent.")
        #expect(NeedsYouCopy.sentBackHeading.text == "{task} was sent back {count} times")
        #expect(NeedsYouCopy.letItTryOnceMore.text == "Let it try once more")
        #expect(NeedsYouCopy.changeTask.text == "Change the task")
        #expect(NeedsYouCopy.cancelTask.text == "Cancel task")
        #expect(NeedsYouCopy.settledBeforeYouSaw.text == "This was settled before you saw it.")
        #expect(ShellCopy.tabNeedsYou.text == "Needs you")
        #expect(ShellCopy.tabHandoff.text == "Handoff")
        #expect(ShellCopy.healthBackupLate.text == "The daily backup is late")
    }

    @Test("no Needs you sentence names the owner's email or says a banned word, filled in or not")
    func needsYouTidy() {
        for text in NeedsYouCopy.allTexts {
            #expect(!text.contains("@"), "\(text)")
            #expect(BannedTerms.found(in: text).isEmpty, "\(text)")
        }
    }

    @Test("every placeholder of a Needs you sentence is one the screen fills in")
    func needsYouPlaceholders() throws {
        // "time": a reset time, which the offline item names (review finding 22).
        let known: Set<String> = ["account", "task", "provider", "count", "time"]
        let regex = try NSRegularExpression(pattern: #"\{(\w+)\}"#)
        for text in NeedsYouCopy.allTexts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                let name = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
                #expect(known.contains(name), "\(name) in \(text)")
            }
        }
    }

    // MARK: Settings, Rules (RM-1, RD-8, RD-17, RD-25)

    @Test("the Rules sentences are the words RM-1 and RD-8 name")
    func rulesSentences() {
        #expect(ShellCopy.tabSettings.text == "Settings")
        #expect(RulesCopy.title.text == "Rules")
        #expect(RulesCopy.scopeAllTasks.text == "Every task")
        // Review finding 26: the owner's words say "the agent that checks", never "checker".
        #expect(RulesCopy.scopeCheckerDecides.text == "The agent that checks decides")
        #expect(RulesCopy.instructionLabel.text == "What the agent checks for")
        for copy in RulesCopy.allCases {
            #expect(!copy.text.lowercased().contains("checker"), "\(copy)")
        }
        #expect(RulesCopy.checkerApp.text == "leverage checks this itself")
        #expect(RulesCopy.checkerModel.text == "An agent checks this")
        #expect(RulesCopy.onFailBlock.text == "Stop the task")
        #expect(RulesCopy.onFailWarn.text == "Only note it")
        #expect(RulesCopy.notActing.text == "Starts working in a later version of leverage")
        #expect(RulesCopy.whenItRuns.text == "When it runs")
        #expect(RulesCopy.wordingOf.text == "Wording of {date}")
        #expect(RulesCopy.revertToDefault.text == "Go back to the original wording")
        #expect(RulesCopy.addRule.text == "Add a rule")
    }

    @Test("the health line says what to do when no agent checks tasks, and when it is not running (RD-17)")
    func orchestratorHealthSentences() {
        #expect(ShellCopy.healthNoOrchestrator.text == "No agent is set up to check tasks. Connect one in Agents.")
        #expect(ShellCopy.healthOrchestratorOffline.text == "The agent that checks tasks is not running.")
    }

    @Test("every moment the contract names reads in plain words")
    func momentNamesArePlain() {
        for hook in RuleHook.allCases {
            #expect(BannedTerms.found(in: hook.momentName).isEmpty, "\(hook.momentName)")
            #expect(hook.momentName == hook.momentName.trimmingCharacters(in: .whitespaces))
            #expect(!hook.momentName.isEmpty)
        }
    }

    @Test("every placeholder of a Rules sentence is one the screen fills in")
    func rulesPlaceholders() throws {
        let known: Set<String> = ["date", "count", "tokens", "time", "amount", "name"]
        let regex = try NSRegularExpression(pattern: #"\{(\w+)\}"#)
        for text in RulesCopy.allTexts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                let name = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
                #expect(known.contains(name), "\(name) in \(text)")
            }
        }
    }
}
