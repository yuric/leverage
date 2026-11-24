/// The owner-facing sentences of the setup assistant
/// (docs/onboarding/setup-assistant.html). A sentence with a `{name}` in it
/// is filled in by `filled(_:)`. Where another screen already has the exact
/// sentence (Credentials, Agents, Add task), the assistant uses that one.
enum SetupAssistantCopy: OwnerFacingCopy {
    // Around every screen.
    case setUpLater, stepsLabel, stepWelcome, stepLogins, stepAgents, stepFirstTask, stepDone
    case continueButton

    // Welcome.
    case welcomeTitle, welcomeBody
    case snapAddTitle, snapAddBody, snapPairTitle, snapPairBody, snapAskTitle, snapAskBody
    case snapBuilds, snapReviews, welcomeFoot, getStarted

    // The two login screens.
    case firstLoginTitle, firstLoginBody, secondLoginTitle, secondLoginBody
    case providersLabel, runsIn, alreadyAdded, geminiTileNote
    case loginsAdded, loginRowLine, nextLogin, checking
    case oneSubscription, oneSubscriptionNote, continueWithOne

    // Agents.
    case agentsTitle, agentsBody, agentsLabel, agentSwitch, agentStarted
    case startAgents, geminiRowNote, oneProviderNote, geminiReviewNote, turnOnOne

    // First task.
    case taskTitle, taskBody, startersLabel, doneWhen, agentTime, writeOwn, ownNeedsCriteria
    case sendToAgents, sending, skipToBoard

    // The three ready-made tasks.
    case categoryApps, categoryWebsites, categoryAutomations
    case todoTime, todoTitle, todoPitch, todoDone1, todoDone2, todoDone3
    case portfolioTime, portfolioTitle, portfolioPitch, portfolioDone1, portfolioDone2, portfolioDone3
    case tidyTime, tidyTitle, tidyPitch, tidyDone1, tidyDone2, tidyDone3
    case reviewLine

    var text: String {
        switch self {
        case .setUpLater: "Set up later"
        case .stepsLabel: "Setup steps"
        case .stepWelcome: "Welcome"
        case .stepLogins: "Logins"
        case .stepAgents: "Agents"
        case .stepFirstTask: "First task"
        case .stepDone: "{step}, done"
        case .continueButton: "Continue"

        case .welcomeTitle: "Welcome to Leverage"
        case .welcomeBody: "Your agents build the work, a second one reviews it, and you are asked only when it matters."
        case .snapAddTitle: "You add a task"
        case .snapAddBody: "Say what should get done, and how you will know."
        case .snapPairTitle: "One agent builds, another reviews"
        case .snapPairBody: "The reviewer comes from a different provider."
        case .snapAskTitle: "You are asked only when it matters"
        case .snapAskBody: "Questions and approvals wait in Needs you."
        case .snapBuilds: "Builds"
        case .snapReviews: "Reviews"
        case .welcomeFoot: "Setup takes about five minutes. You need two AI subscriptions you already pay for."
        case .getStarted: "Get started"

        case .firstLoginTitle: "Add your first login"
        case .firstLoginBody:
            "Agents run on a subscription you already have. The login stays inside its own tool on this Mac."
        case .secondLoginTitle: "Add a second login, from a different provider"
        case .secondLoginBody:
            "An agent from another provider reviews the work before it counts as done. With one provider, finished work waits with nobody to review it."
        case .providersLabel: "Provider"
        case .runsIn: "Runs in {tool}"
        case .alreadyAdded: "Already added"
        case .geminiTileNote: "Builds, but does not review yet"
        case .loginsAdded: "Logins added"
        case .loginRowLine: "Subscription login. Signed in and answering."
        case .nextLogin: "Next, a second login from a different provider."
        case .checking: "Checking {login}"
        case .oneSubscription: "I only have one subscription"
        case .oneSubscriptionNote:
            "You can continue with one. Finished work will wait in Needs you until a second provider is added, or until you turn the review rule off in Settings."
        case .continueWithOne: "Continue with one"

        case .agentsTitle: "Your agents are ready"
        case .agentsBody: "Leverage made one agent for each login. Each can build, review and check tasks."
        case .agentsLabel: "Agents"
        case .agentSwitch: "Agent on {login}"
        case .agentStarted: "Started"
        case .startAgents: "Start agents"
        case .geminiRowNote: "Builds, but does not review yet."
        case .oneProviderNote:
            "With one provider, finished work will wait in Needs you until a second provider is added, or until you turn the review rule off in Settings."
        case .geminiReviewNote:
            "Gemini does not review yet. {other} reviews what Gemini builds, and what {other} builds will wait for another reviewer."
        case .turnOnOne: "Turn on at least one agent to continue."

        case .taskTitle: "Give them something to do"
        case .taskBody: "Pick a ready-made task, or write your own. You can change every word."
        case .startersLabel: "Ready-made tasks"
        case .doneWhen: "Done when"
        case .agentTime: "{time} of agent time."
        case .writeOwn: "Write my own"
        case .ownNeedsCriteria: "Say how you will know it is done, so it can be sent to agents."
        case .sendToAgents: "Send to agents"
        case .sending: "Sending…"
        case .skipToBoard: "Skip, take me to the board"

        case .categoryApps: "Apps"
        case .categoryWebsites: "Websites"
        case .categoryAutomations: "Automations"
        case .todoTime: "~40 min"
        case .todoTitle: "Pocket to-do"
        case .todoPitch: "A calm to-do app that lives on your Mac. No account, no cloud."
        case .todoDone1: "Tasks are still there after the app restarts"
        case .todoDone2: "The N and Space shortcuts work"
        case .todoDone3: "Tests pass with the command in the README"
        case .portfolioTime: "~25 min"
        case .portfolioTitle: "Glass portfolio"
        case .portfolioPitch: "A one-page portfolio with frosted glass and drifting color."
        case .portfolioDone1: "The page opens from one file, with nothing to install"
        case .portfolioDone2: "It reads well on a phone and on a wide screen"
        case .portfolioDone3: "Text stays easy to read over the glass"
        case .tidyTime: "~15 min"
        case .tidyTitle: "Downloads tidy-up"
        case .tidyPitch: "Sorts a messy folder, and shows you the plan before it moves a thing."
        case .tidyDone1: "It shows the plan before it moves anything"
        case .tidyDone2: "Nothing is deleted"
        case .tidyDone3: "Running it a second time changes nothing"
        case .reviewLine: "A second agent reviews the work"
        }
    }
}
