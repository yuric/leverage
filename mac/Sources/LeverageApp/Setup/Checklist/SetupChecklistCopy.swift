/// The owner-facing sentences of the setup checklist and its spotlight, from
/// docs/onboarding/checklist-spotlight.html. A sentence with a `{name}` in it
/// is filled in by `filled(_:)`.
enum SetupChecklistCopy: OwnerFacingCopy {
    // The card's head.
    case title, subtitle, progress, meterLabel, hide, showMe

    // The four steps.
    case loginsTitle, loginsBody, loginsOneAdded
    case agentsTitle, agentsBody, agentsOneConnected, agentsDone
    case firstTaskTitle, firstTaskBody, firstTaskDone
    case doneTitle, doneBody, doneDone, doneSent
    case names, twoNames

    // The finished strip.
    case finishedTitle, finishedBody, finishSetup

    // The side pane.
    case sidePaneTitle

    // The line after the assistant sent a first task.
    case sentTaskLine, close

    // The spotlight's note.
    case noteStep, notNow
    case loginsTabFirstTitle, loginsTabFirstBody, loginsTabMoreTitle, loginsTabMoreBody
    case addCredentialFirstTitle, addCredentialFirstBody, addCredentialMoreTitle, addCredentialMoreBody
    case agentsTabFirstTitle, agentsTabFirstBody, agentsTabMoreTitle, agentsTabMoreBody
    case connectFirstTitle, connectMoreTitle, connectMoreNoLoginTitle, connectBody, connectNoLoginBody
    case addTaskTitle, addTaskBody
    case finishedNoteTitle, finishedNoteBody

    // The help inside Add credential.
    case addCredentialHint

    var text: String {
        switch self {
        case .title: "Get your first task done"
        case .subtitle: "Four steps. Each one ticks when it is true, so you can stop and come back."
        case .progress: "{done} of 4"
        case .meterLabel: "{done} of 4 done"
        case .hide: "Hide this"
        case .showMe: "Show me"

        case .loginsTitle: "Add two logins"
        case .loginsBody: "From different providers, so one agent can review the other’s work."
        case .loginsOneAdded: "1 of 2 added."
        case .agentsTitle: "Connect an agent for each"
        case .agentsBody: "An agent does the work and runs on a login."
        case .agentsOneConnected: "1 of 2 connected."
        case .agentsDone: "{names} are connected."
        case .firstTaskTitle: "Send your first task"
        case .firstTaskBody: "Use Add task to write what should get done."
        case .firstTaskDone: "{task}."
        case .doneTitle: "See it reach Done"
        case .doneBody: "One agent builds it, the other reviews it. You are asked only if they need you."
        case .doneDone: "It reached Done."
        case .doneSent: "Sent to your agents"
        case .names: "{names}."
        case .twoNames: "{first} and {second}"

        case .finishedTitle: "Setup is finished."
        case .finishedBody: "For the next one, use Add task."
        case .finishSetup: "Finish setup"

        case .sidePaneTitle: "Setup"

        case .sentTaskLine:
            "You are set up. Your agents will pick up {task}. Anything that needs you shows up in Needs you."
        case .close: "Close"

        case .noteStep: "Step {step} of 4"
        case .notNow: "Not now"
        case .loginsTabFirstTitle: "Start here: add a login"
        case .loginsTabFirstBody:
            "Agents run on a subscription you already have, like Claude or Codex. Until one is added, no task can run."
        case .loginsTabMoreTitle: "One more login to add"
        case .loginsTabMoreBody:
            "It has to come from a different provider than {provider}, so one agent can review the other’s work."
        case .addCredentialFirstTitle: "Add your first login"
        case .addCredentialFirstBody:
            "Pick the provider, name it and sign in. Leverage checks that it is installed, signed in and answering."
        case .addCredentialMoreTitle: "Now a second, from a different provider"
        case .addCredentialMoreBody:
            "An agent from another provider reviews the work before it counts as done. Pick anything but {provider}."
        case .agentsTabFirstTitle: "Next: connect your agents"
        case .agentsTabFirstBody: "A login is only a way in. An agent is what does the work. Connect one for each login."
        case .agentsTabMoreTitle: "Connect the second agent"
        case .agentsTabMoreBody: "With two agents, one builds and the other reviews."
        case .connectFirstTitle: "Connect an agent"
        case .connectMoreTitle: "One more, on {login}"
        case .connectMoreNoLoginTitle: "One more, on your other login"
        case .connectBody: "It is filled in for you to run on {login}. General means it can build, review and check tasks."
        case .connectNoLoginBody: "Pick the login it runs on. General means it can build, review and check tasks."
        case .addTaskTitle: "Give them something to do"
        case .addTaskBody: "Use Add task to write what should get done. One agent builds it and the other reviews it."
        case .finishedNoteTitle: "Your first task is done"
        case .finishedNoteBody:
            "Open the card any time to see how it got there, and who reviewed it."

        case .addCredentialHint: "Pick a different provider from {provider}, so one agent can review the other’s work."
        }
    }
}
