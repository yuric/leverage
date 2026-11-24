import Foundation

/// What the spotlight lights, and what its note says.
struct SetupGuideNote: Equatable, Sendable {
    /// Which side of the lit control the note sits on.
    enum Side: Equatable, Sendable {
        case right, below, left
    }

    let target: SpotlightTarget
    let side: Side
    /// The checklist step it belongs to, 1 to 4.
    let step: Int
    let title: String
    let body: String
    /// The last note: Finish setup instead of Not now.
    let offersFinish: Bool

    /// "Step 2 of 4".
    var stepLine: String { SetupChecklistCopy.noteStep.filled(["step": String(step)]) }

    /// The note as one accessibility element: its title and its sentence.
    var accessibilityLabel: String { "\(title). \(body)" }
}

/// Decides what the spotlight lights from what is true in the workspace and
/// where the owner is (docs/onboarding/checklist-spotlight.html, `guideSpec()`).
/// The app has no ready-made tasks, so the third step lights Add task alone;
/// while the first task runs nothing is lit; the last note is drawn on the
/// task board only.
enum SetupGuide {
    static func note(for facts: SetupModel.Facts, place: Navigator.Place, taskPageOpen: Bool) -> SetupGuideNote? {
        guard !taskPageOpen else { return nil }
        guard let current = facts.current else {
            guard place == .board, facts.doneTask != nil else { return nil }
            return SetupGuideNote(
                target: .doneTask, side: .left, step: 4, title: SetupChecklistCopy.finishedNoteTitle.text,
                body: SetupChecklistCopy.finishedNoteBody.text, offersFinish: true)
        }
        switch current {
        case .logins: return logins(facts, place: place)
        case .agents: return agents(facts, place: place)
        case .firstTask:
            return SetupGuideNote(
                target: .addTask, side: .below, step: 3, title: SetupChecklistCopy.addTaskTitle.text,
                body: SetupChecklistCopy.addTaskBody.text, offersFinish: false)
        case .done:
            // The task is running: there is nothing to click.
            return nil
        }
    }

    /// The note to draw now, or nil: only on the checklist, while the
    /// spotlight is on and no sheet is open.
    @MainActor
    static func visibleNote(_ setup: SetupModel, navigator: Navigator) -> SetupGuideNote? {
        guard setup.presentation == .checklist, setup.spotlightOn, !setup.isSheetOpen else { return nil }
        return note(for: setup.facts, place: navigator.place, taskPageOpen: navigator.openTaskID != nil)
    }

    private static func logins(_ facts: SetupModel.Facts, place: Navigator.Place) -> SetupGuideNote {
        let first = facts.logins.isEmpty
        let other = facts.loginProviders.first.map(ProviderNames.name) ?? ""
        if place != .credentials {
            return SetupGuideNote(
                target: .credentialsTab, side: .right, step: 1,
                title: (first ? SetupChecklistCopy.loginsTabFirstTitle : .loginsTabMoreTitle).text,
                body: first ? SetupChecklistCopy.loginsTabFirstBody.text
                    : SetupChecklistCopy.loginsTabMoreBody.filled(["provider": other]),
                offersFinish: false)
        }
        return SetupGuideNote(
            target: .addCredential, side: .below, step: 1,
            title: (first ? SetupChecklistCopy.addCredentialFirstTitle : .addCredentialMoreTitle).text,
            body: first ? SetupChecklistCopy.addCredentialFirstBody.text
                : SetupChecklistCopy.addCredentialMoreBody.filled(["provider": other]),
            offersFinish: false)
    }

    private static func agents(_ facts: SetupModel.Facts, place: Navigator.Place) -> SetupGuideNote {
        let first = facts.agents.isEmpty
        if place != .agents {
            return SetupGuideNote(
                target: .agentsTab, side: .right, step: 2,
                title: (first ? SetupChecklistCopy.agentsTabFirstTitle : .agentsTabMoreTitle).text,
                body: (first ? SetupChecklistCopy.agentsTabFirstBody : .agentsTabMoreBody).text, offersFinish: false)
        }
        let login = facts.nextLoginWithoutAgent?.label
        let title: String
        if first {
            title = SetupChecklistCopy.connectFirstTitle.text
        } else if let login {
            title = SetupChecklistCopy.connectMoreTitle.filled(["login": login])
        } else {
            title = SetupChecklistCopy.connectMoreNoLoginTitle.text
        }
        let body = login.map { SetupChecklistCopy.connectBody.filled(["login": $0]) }
            ?? SetupChecklistCopy.connectNoLoginBody.text
        return SetupGuideNote(target: .connectAgent, side: .below, step: 2, title: title, body: body, offersFinish: false)
    }
}
