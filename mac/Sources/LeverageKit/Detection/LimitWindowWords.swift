import Foundation

/// The one list of words that name a limit's window (plan HD-7), shared by
/// the four detectors. A structured field is read by `window(named:)`; free
/// text by `windows(in:)`, which takes only whole words.
///
/// No tool's limit reply has been seen (`inventory-providers.md` §7), so
/// beyond the contract's own four words these are a guess at what a reply
/// might say.
public enum LimitWindowWords {
    private static let table: [LimitWindow: [String]] = [
        .fiveHour: ["five_hour", "five-hour", "five hour", "5-hour", "5 hour"],
        .weekly: ["weekly"],
        .perModel: ["per_model", "per-model", "per model"],
        .spend: ["spend"],
    ]

    /// The words that name `window`, the contract's own word first.
    public static func words(for window: LimitWindow) -> [String] { table[window] ?? [] }

    /// The window a structured field's value names: one of the words, in any
    /// case, with no other text around it.
    public static func window(named field: String) -> LimitWindow? {
        let value = field.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return LimitWindow.allCases.first { words(for: $0).contains(value) }
    }

    /// Every window the text names by a whole word, in the order of its
    /// first mention.
    public static func windows(in text: String) -> [LimitWindow] {
        let lower = text.lowercased()
        var first: [(LimitWindow, String.Index)] = []
        for window in LimitWindow.allCases {
            let positions = words(for: window).compactMap { firstWholeWord($0, in: lower) }
            if let earliest = positions.min() { first.append((window, earliest)) }
        }
        return first.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The window the text names first, if any.
    public static func window(in text: String) -> LimitWindow? { windows(in: text).first }

    private static func firstWholeWord(_ word: String, in text: String) -> String.Index? {
        var searchFrom = text.startIndex
        while let found = text.range(of: word, range: searchFrom..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return found.lowerBound }
            searchFrom = text.index(after: found.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
