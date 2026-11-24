/// The three ready-made tasks of the assistant's last screen
/// (docs/onboarding/setup-assistant.html). The words the owner reads are
/// cases of `SetupAssistantCopy`; the prompt is what the agents read as the
/// task's goal, from the gallery mockup with its example values filled in.
struct StarterTask: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case todo, portfolio, tidy
    }

    /// The picture at the top of its card.
    enum Art: Sendable {
        case apps, web, spark
    }

    let kind: Kind
    let category: SetupAssistantCopy
    let time: SetupAssistantCopy
    let title: SetupAssistantCopy
    let pitch: SetupAssistantCopy
    /// The lines sent as the task's criteria. The independent review is
    /// added after them by the Add task form, as on every task.
    let doneWhen: [SetupAssistantCopy]
    let prompt: String
    /// The card's gradient, left to right, as `0xRRGGBB`.
    let gradient: [UInt32]
    let art: Art

    var id: Kind { kind }

    /// The criteria as the Add task form takes them: one on each line.
    var criteriaText: String { doneWhen.map(\.text).joined(separator: "\n") }

    static let all: [StarterTask] = [todo, portfolio, tidy]

    static func task(_ kind: Kind) -> StarterTask {
        switch kind {
        case .todo: todo
        case .portfolio: portfolio
        case .tidy: tidy
        }
    }

    static let todo = StarterTask(
        kind: .todo, category: .categoryApps, time: .todoTime, title: .todoTitle, pitch: .todoPitch,
        doneWhen: [.todoDone1, .todoDone2, .todoDone3],
        prompt: """
            Build a local to-do app styled like a paper notebook with soft grain.

            Features: add, edit, complete and delete tasks; tags, due dates and a Today view; keyboard shortcuts N \
            (new) and Space (complete). Save everything in a local SQLite file so it survives restarts.

            It runs with one command and opens in the browser. Include tests for creating, completing and \
            filtering tasks.
            """,
        gradient: [0x4ADE80, 0x7DF3E1, 0x38BDF8], art: .apps)

    static let portfolio = StarterTask(
        kind: .portfolio, category: .categoryWebsites, time: .portfolioTime, title: .portfolioTitle,
        pitch: .portfolioPitch, doneWhen: [.portfolioDone1, .portfolioDone2, .portfolioDone3],
        prompt: """
            Build a one-page portfolio site for Alex Rivera, a product designer.

            Look: frosted-glass cards over slowly drifting sunset pink and violet gradient blobs, a big confident \
            headline, generous spacing.
            Sections: hero, selected work (6 project cards with placeholder images), about, contact links.

            Plain HTML, CSS and a little JavaScript; it opens straight from index.html with no build step. \
            Readable at phone width, every text passes WCAG AA contrast, and animation stops when the visitor \
            prefers reduced motion.
            """,
        gradient: [0x60A5FA, 0xA5B4FC, 0xC084FC], art: .web)

    static let tidy = StarterTask(
        kind: .tidy, category: .categoryAutomations, time: .tidyTime, title: .tidyTitle, pitch: .tidyPitch,
        doneWhen: [.tidyDone1, .tidyDone2, .tidyDone3],
        prompt: """
            Write a script that organizes ~/Downloads into folders by file type, then month.

            By default it does a dry run and prints exactly what it would move; it only moves files with --apply. \
            It never deletes anything, skips files changed in the last hour, and writes an undo log so one \
            command puts everything back.
            """,
        gradient: [0xFDE047, 0x86EFAC, 0x14B8A6], art: .spark)
}
