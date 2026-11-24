import Foundation
import LeverageKit

/// What the setup checklist card says, from what is true in the workspace
/// and what the task board already knows. Every step ticks from the facts,
/// never from a click.
struct SetupChecklistContent: Equatable {
    enum StepState: Equatable, Sendable {
        case done, current, later
    }

    /// What sits at the foot of a step.
    enum Foot: Equatable, Sendable {
        /// The Done chip.
        case done
        /// The Show me button, on the current step.
        case showMe
        /// The task's own line while the last step is current: nothing to click.
        case live(String)
        case none
    }

    struct Step: Identifiable, Equatable {
        let step: SetupModel.Step
        let title: String
        let body: String
        let state: StepState
        let foot: Foot

        var id: Int { step.rawValue }
    }

    let doneCount: Int
    let steps: [Step]
    /// All four steps are done: the card is the finished strip.
    let isFinished: Bool

    var title: String { SetupChecklistCopy.title.text }
    var subtitle: String { SetupChecklistCopy.subtitle.text }
    var progress: String { Self.progress(doneCount) }
    var meterLabel: String { SetupChecklistCopy.meterLabel.filled(["done": String(doneCount)]) }
    var finishedTitle: String { SetupChecklistCopy.finishedTitle.text }
    var finishedBody: String { SetupChecklistCopy.finishedBody.text }

    /// "2 of 4", for the card and the side pane.
    static func progress(_ done: Int) -> String { SetupChecklistCopy.progress.filled(["done": String(done)]) }

    /// `cards` are the task board's cards; the sent task's card gives the
    /// last step its line while it runs.
    init(facts: SetupModel.Facts, cards: [BoardCard]) {
        doneCount = facts.doneCount
        isFinished = facts.allDone
        let current = facts.current
        steps = SetupModel.Step.allCases.map { step in
            let done = facts.isDone(step)
            let state: StepState = done ? .done : step == current ? .current : .later
            let foot: Foot
            switch state {
            case .done: foot = .done
            case .later: foot = .none
            case .current:
                foot = step == .done ? .live(Self.liveLine(facts: facts, cards: cards)) : .showMe
            }
            return Step(
                step: step, title: Self.title(step), body: Self.body(step, facts: facts, done: done), state: state,
                foot: foot)
        }
    }

    /// The line of the sent task's card, or one plain sentence when the
    /// board has not shown that card.
    static func liveLine(facts: SetupModel.Facts, cards: [BoardCard]) -> String {
        guard let id = facts.sentTask?.id, let card = cards.first(where: { $0.id == id }) else {
            return SetupChecklistCopy.doneSent.text
        }
        return card.statusLine
    }

    private static func title(_ step: SetupModel.Step) -> String {
        switch step {
        case .logins: SetupChecklistCopy.loginsTitle.text
        case .agents: SetupChecklistCopy.agentsTitle.text
        case .firstTask: SetupChecklistCopy.firstTaskTitle.text
        case .done: SetupChecklistCopy.doneTitle.text
        }
    }

    private static func body(_ step: SetupModel.Step, facts: SetupModel.Facts, done: Bool) -> String {
        switch step {
        case .logins:
            if done { return SetupChecklistCopy.names.filled(["names": joined(facts.logins.map(\.label))]) }
            return counted(SetupChecklistCopy.loginsBody, facts.loginProviders.count, SetupChecklistCopy.loginsOneAdded)
        case .agents:
            if done { return SetupChecklistCopy.agentsDone.filled(["names": joined(facts.agents.map(\.name))]) }
            return counted(
                SetupChecklistCopy.agentsBody, facts.agentProviders.count, SetupChecklistCopy.agentsOneConnected)
        case .firstTask:
            if done, let task = facts.sentTask {
                return SetupChecklistCopy.firstTaskDone.filled(["task": task.title])
            }
            return SetupChecklistCopy.firstTaskBody.text
        case .done:
            return (done ? SetupChecklistCopy.doneDone : .doneBody).text
        }
    }

    /// The step's sentence, with "1 of 2" after it once one of two is there.
    private static func counted(_ body: SetupChecklistCopy, _ count: Int, _ one: SetupChecklistCopy) -> String {
        count == 1 ? "\(body.text) \(one.text)" : body.text
    }

    /// "A and B", "A and B and C": a label holds a comma, so none joins them.
    private static func joined(_ names: [String]) -> String {
        guard var result = names.first else { return "" }
        for name in names.dropFirst() {
            result = SetupChecklistCopy.twoNames.filled(["first": result, "second": name])
        }
        return result
    }
}

/// The two helps setup gives inside sheets that exist without it.
@MainActor
enum SetupChecklistHelp {
    /// Add credential's line above the providers: on the checklist, when
    /// exactly one provider has a login.
    static func addCredentialHint(_ setup: SetupModel) -> String? {
        guard setup.presentation == .checklist, setup.facts.loginProviders.count == 1,
              let provider = setup.facts.loginProviders.first
        else { return nil }
        return SetupChecklistCopy.addCredentialHint.filled(["provider": ProviderNames.name(provider)])
    }

    /// The login Connect agent opens with: on the checklist, the next one no
    /// agent runs on.
    static func preferredLoginID(_ setup: SetupModel) -> UUID? {
        guard setup.presentation == .checklist else { return nil }
        return setup.facts.nextLoginWithoutAgent?.id
    }
}

extension SetupModel {
    /// "Show me" on the checklist's current step.
    func showMe() { spotlightOn = true }

    /// "Not now" on the spotlight's note, and Escape.
    func notNow() { spotlightOn = false }

    /// "Hide this" on the checklist card: setup is over, as with Finish setup.
    func hideChecklist() { finishChecklist() }
}
