import Foundation

/// What the four detectors share (plan HD-7): finding JSON in a tool's
/// output, a time a reply states, and the one order in which a refusal's
/// text is read. Foundation only, so it builds on Linux too.
///
/// It is given the tool's error text only, never the agent's answer: each
/// detector picks that text out of its tool's output first.
enum ReplyReading {
    /// The JSON objects in `text`: the whole of it as one object, or else
    /// each line that is one (JSON lines).
    static func jsonObjects(in text: String) -> [[String: Any]] {
        if let object = object(from: text) { return [object] }
        return text.split(whereSeparator: \.isNewline).compactMap { object(from: String($0)) }
    }

    private static func object(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    /// A time a structured field gives in seconds since 1970.
    static func time(fromSeconds value: Any?) -> Date? {
        switch value {
        case let number as NSNumber: Date(timeIntervalSince1970: number.doubleValue)
        case let text as String: Double(text).map(Date.init(timeIntervalSince1970:))
        default: nil
        }
    }

    /// The first ISO 8601 time (`2026-11-19T12:00:00Z`, with or without
    /// fractions of a second, `Z` or an offset) the text states after a
    /// reset word ("resets", "reset at", "try again at", in any case) on the
    /// same line. A time with no reset word before it, such as a log line's
    /// own leading timestamp, or after a bare "reset" or a "try again" with
    /// no "at", is no reset time. Nothing is estimated (L615): a
    /// reply that says "in two hours" states no time.
    static func statedTime(in text: String) -> Date? {
        guard let iso = try? NSRegularExpression(pattern: isoPattern),
            let word = try? NSRegularExpression(pattern: resetWordPattern, options: [.caseInsensitive])
        else { return nil }
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let whole = NSRange(line.startIndex..., in: line)
            guard let reset = word.firstMatch(in: line, range: whole) else { continue }
            let after = NSRange(location: reset.range.upperBound, length: whole.length - reset.range.upperBound)
            for match in iso.matches(in: line, range: after) {
                guard let found = Range(match.range, in: line) else { continue }
                if let date = parseISO(String(line[found])) { return date }
            }
        }
        return nil
    }

    private static let resetWordPattern = #"\b(resets|reset at|try again at)\b"#

    private static let isoPattern =
        #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})"#

    private static func parseISO(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// The outcome of a refusal, read from the tool's error text in this
    /// order: a sign-out (one of the provider's own phrases); a limit, which
    /// names one of the four windows, by a structured field or by the word
    /// "limit" or "quota" beside the window's words, with the reset time a
    /// structured field gives or the text states; a short rate limit, which
    /// names no window (429, "rate limit", "too many requests", a usage
    /// limit or a quota with no window); anything else, a context or output
    /// "limit" among them, is a failure.
    static func outcome(
        errorText: String, signedOutPhrases: [String], structuredWindow: String? = nil,
        structuredReset: Date? = nil
    ) -> RunOutcome {
        let lower = errorText.lowercased()
        if signedOutPhrases.contains(where: { lower.contains($0) }) { return .signedOut }
        let namesALimit = containsWholeWord(["limit", "limits", "quota"], in: lower)
        let window = structuredWindow.flatMap(LimitWindowWords.window(named:))
            ?? (namesALimit ? LimitWindowWords.window(in: errorText) : nil)
        if let window {
            return .limit(window: window, resetAt: structuredReset ?? statedTime(in: errorText))
        }
        let rateLimited = containsWholeWord(["429", "quota"], in: lower)
            || ["rate limit", "rate_limit", "too many requests", "resource_exhausted", "usage limit"]
                .contains(where: { lower.contains($0) })
        return rateLimited ? .rateLimited : .failed
    }

    private static func containsWholeWord(_ words: [String], in text: String) -> Bool {
        words.contains { word in
            var from = text.startIndex
            while let found = text.range(of: word, range: from..<text.endIndex) {
                let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
                if !isWordCharacter(before), !isWordCharacter(after) { return true }
                from = text.index(after: found.lowerBound)
            }
            return false
        }
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}

extension ToolRunRecord {
    /// True when the tool ended by itself with exit status 0.
    var exitedZero: Bool { termination == .exited(0) }

    /// True when the tool exited by itself: leverage did not end it (its
    /// time limit, a stop) and no signal killed it (a crash, an outside
    /// kill). Only such a run is read for a limit or a sign-out: any other
    /// was cut off before it finished its reply.
    var endedByItself: Bool {
        guard endedBy == nil, case .exited = termination else { return false }
        return true
    }
}
