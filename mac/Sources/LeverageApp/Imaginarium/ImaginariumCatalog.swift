import Foundation

/// The Imaginarium's prompt catalog (PRD FR-026 to FR-029): versioned JSON
/// compiled into the app, as the string in `ImaginariumCatalogData.swift`,
/// so that it needs no resource bundle. The app never fetches prompts from
/// the network.
struct ImaginariumCatalog: Decodable, Equatable, Sendable {
    let version: Int
    let categories: [Category]
    let entries: [Entry]

    struct Category: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    /// A blank the owner fills in; the prompt names it as `{key}`.
    struct Fill: Decodable, Equatable, Sendable {
        let key: String
        let label: String
        let defaultValue: String

        enum CodingKeys: String, CodingKey {
            case key, label
            case defaultValue = "default"
        }
    }

    /// What an entry needs beyond a coding agent. An entry that names
    /// anything else does not decode (FR-028).
    enum Need: String, Decodable, Equatable, Sendable, CaseIterable {
        case imageTool = "image_tool"
    }

    struct Entry: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let category: String
        let title: String
        let description: String
        let minutes: Int
        let fills: [Fill]
        let prompt: String
        let doneWhen: [String]
        let needs: [Need]

        enum CodingKeys: String, CodingKey {
            case id, category, title, description, minutes, fills, prompt, needs
            case doneWhen = "done_when"
        }

        /// The prompt with each `{key}` replaced by the owner's value for that
        /// fill-in, or by its default when the owner gave none.
        func filledPrompt(_ values: [String: String] = [:]) -> String {
            fills.reduce(prompt) { text, fill in
                text.replacingOccurrences(of: "{\(fill.key)}", with: values[fill.key] ?? fill.defaultValue)
            }
        }
    }

    /// The catalog the app ships.
    static func launch() throws -> ImaginariumCatalog {
        try decode(ImaginariumCatalogData.json)
    }

    static func decode(_ json: String) throws -> ImaginariumCatalog {
        try JSONDecoder().decode(ImaginariumCatalog.self, from: Data(json.utf8))
    }

    /// Everything FR-028 forbids, one line per defect; empty for a sound
    /// catalog. An unknown need is caught earlier: it does not decode.
    func problems() -> [String] {
        var found: [String] = []
        found += Self.duplicates(categories.map(\.id)).map { "category \($0) is listed twice" }
        found += categories.filter { $0.name.isEmpty }.map { "category \($0.id) has no name" }
        found += Self.duplicates(entries.map(\.id)).map { "entry \($0) is listed twice" }
        let categoryIDs = Set(categories.map(\.id))
        for entry in entries {
            found += Self.problems(of: entry, categoryIDs: categoryIDs).map { "\(entry.id): \($0)" }
        }
        return found
    }

    // Computed, because a Regex is not Sendable and cannot be a shared static.
    private static var entryID: Regex<(Substring, Substring?)> { /^[a-z0-9]+(-[a-z0-9]+)*$/ }
    private static var fillKey: Regex<Substring> { /^[a-z][a-z0-9_]*$/ }
    private static var placeholder: Regex<(Substring, Substring)> { /\{([a-z][a-z0-9_]*)\}/ }

    private static func problems(of entry: Entry, categoryIDs: Set<String>) -> [String] {
        var found: [String] = []
        if entry.id.wholeMatch(of: entryID) == nil { found.append("the id is not lowercase kebab-case") }
        if !categoryIDs.contains(entry.category) { found.append("category \(entry.category) does not exist") }
        for (name, text) in [("title", entry.title), ("description", entry.description), ("prompt", entry.prompt)]
        where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("the \(name) is empty")
        }
        if entry.minutes <= 0 { found.append("the time estimate is not positive") }
        if !(1...4).contains(entry.fills.count) { found.append("it has \(entry.fills.count) fill-ins, not 1 to 4") }
        if !(2...4).contains(entry.doneWhen.count) {
            found.append("it has \(entry.doneWhen.count) Done when checks, not 2 to 4")
        }
        if entry.doneWhen.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            found.append("a Done when check is empty")
        }
        found += duplicates(entry.fills.map(\.key)).map { "fill-in \($0) is listed twice" }
        for fill in entry.fills {
            if fill.key.wholeMatch(of: fillKey) == nil { found.append("fill-in \(fill.key) is not lowercase snake_case") }
            if fill.label.isEmpty || fill.defaultValue.isEmpty { found.append("fill-in \(fill.key) has no label or default") }
        }
        let named = Set(entry.prompt.matches(of: placeholder).map { String($0.output.1) })
        let keys = Set(entry.fills.map(\.key))
        found += named.subtracting(keys).sorted().map { "the prompt names {\($0)}, which has no fill-in" }
        found += keys.subtracting(named).sorted().map { "fill-in \($0) is not used in the prompt" }
        if entry.prompt.replacing(placeholder, with: "").contains(where: { $0 == "{" || $0 == "}" }) {
            found.append("the prompt holds a brace that names no fill-in")
        }
        return found
    }

    private static func duplicates(_ values: [String]) -> [String] {
        Dictionary(grouping: values, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }
}
