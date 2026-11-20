import Foundation
import LeverageKit

/// What the Needs you rows and the notifications name: the task titles and the
/// accounts, from the board and the credentials reads. Never an email.
struct NeedsYouNames: Sendable {
    var tasks: [UUID: String] = [:]
    var credentials: [UUID: Credential] = [:]

    /// The task's title, or "A task" when the board did not say.
    func taskTitle(_ id: UUID?) -> String {
        id.flatMap { tasks[$0] } ?? NeedsYouCopy.aTask.text
    }

    /// "Claude, Personal": the provider and the name, never the email.
    func accountName(_ id: UUID?) -> String {
        guard let credential = id.flatMap({ credentials[$0] }) else { return NeedsYouCopy.anAccount.text }
        return "\(ProviderNames.name(credential.provider)), \(credential.name)"
    }

    func provider(of id: UUID?) -> Provider? { id.flatMap { credentials[$0]?.provider } }

    /// Reads the board and the credentials, in that order, so that the lower
    /// of their two positions is a point the events tail can start from
    /// before the inbox was read.
    static func read(from owner: any OwnerAPI) async throws -> (names: NeedsYouNames, asOfSeq: Int) {
        let board = try await owner.board()
        let list = try await owner.credentials()
        var names = NeedsYouNames()
        for entry in board.tasks { names.tasks[entry.task.id] = entry.task.title }
        for entry in list.credentials { names.credentials[entry.credential.id] = entry.credential }
        return (names, min(board.asOfSeq, list.asOfSeq))
    }
}

/// One button of an item, with the command it sends.
struct NeedsYouButton: Identifiable, Equatable, Sendable {
    enum Action: String, Sendable {
        case signInAgain, allowAnotherTry, changeTask, cancelTask
        case letThroughOnce, runAgain, turnRuleOff, connectAgent
    }

    let action: Action
    let label: String
    var id: Action { action }
}

/// The words of each item kind (HM-24), shared by the screen and the notifier.
enum NeedsYouWords {
    /// Whether the screen can open an item of this kind: every choice it
    /// offers has a route (HM-21). That is the three of milestone 3 and the
    /// five of the rule checks.
    static func isShown(_ kind: NeedsYouItem) -> Bool {
        switch kind {
        case .accountSignedOut, .limitWithNoResetTime, .pastRoundLimit: true
        case .refusedForEveryAgent, .checkPastRerunLimit, .checkCouldNotRun, .noReviewerEligible,
            .orchestratorOffline: true
        default: false
        }
    }

    /// The kinds whose item names a rule, and so a rule's name to show.
    static func namesARule(_ kind: NeedsYouItem) -> Bool {
        switch kind {
        case .refusedForEveryAgent, .checkPastRerunLimit, .checkCouldNotRun, .noReviewerEligible: true
        default: false
        }
    }

    /// The rule an item names, from its facts.
    static func ruleID(of item: InboxItem) -> UUID? {
        item.facts["rule_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The rule check an item names, from its facts.
    static func checkID(of item: InboxItem) -> UUID? {
        item.facts["rule_check_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The account an item names: its own, or the one its facts name.
    static func credentialID(of item: InboxItem) -> UUID? {
        if let id = item.credentialID { return id }
        return item.facts["credential_id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The task an item is about; nil for an item about a project or the workspace.
    static func taskID(of item: InboxItem) -> UUID? { item.aboutKind == .task ? item.aboutID : nil }

    static func heading(for item: InboxItem, names: NeedsYouNames) -> String {
        let task = names.taskTitle(taskID(of: item))
        let account = names.accountName(credentialID(of: item))
        switch item.kind {
        case .accountSignedOut: return NeedsYouCopy.signedOutHeading.filled(["account": account])
        case .limitWithNoResetTime: return NeedsYouCopy.limitHeading.filled(["account": account])
        case .pastRoundLimit:
            return NeedsYouCopy.sentBackHeading.filled(["task": task, "count": String(sentBack(item))])
        case .refusedForEveryAgent: return NeedsYouCopy.refusedHeading.text
        case .checkPastRerunLimit: return NeedsYouCopy.rerunHeading.text
        case .checkCouldNotRun: return NeedsYouCopy.couldNotRunHeading.text
        case .noReviewerEligible: return NeedsYouCopy.noReviewerHeading.text
        case .orchestratorOffline: return NeedsYouCopy.offlineHeading.text
        default: return NeedsYouCopy.unknownLine.filled(["task": task])
        }
    }

    static func body(for item: InboxItem, names: NeedsYouNames) -> String {
        let task = names.taskTitle(taskID(of: item))
        let credential = credentialID(of: item)
        let account = names.accountName(credential)
        switch item.kind {
        case .accountSignedOut:
            return NeedsYouCopy.signedOutBody.filled(["task": task, "account": account])
        case .limitWithNoResetTime:
            let provider = names.provider(of: credential).map(ProviderNames.name) ?? NeedsYouCopy.anAccount.text
            return NeedsYouCopy.limitBody.filled(["task": task, "account": account, "provider": provider])
        case .pastRoundLimit: return NeedsYouCopy.sentBackBody.text
        case .refusedForEveryAgent: return NeedsYouCopy.refusedBody.filled(["task": task])
        case .checkPastRerunLimit: return NeedsYouCopy.rerunBody.filled(["task": task])
        case .checkCouldNotRun: return NeedsYouCopy.couldNotRunBody.filled(["task": task])
        case .noReviewerEligible: return NeedsYouCopy.noReviewerBody.filled(["task": task])
        case .orchestratorOffline:
            let waiting = item.waitingChecks ?? 0
            var lines: [String] = []
            if waiting == 1 {
                lines.append(NeedsYouCopy.offlineBodyOne.filled(["count": "1"]))
            } else if waiting > 1 {
                lines.append(NeedsYouCopy.offlineBodyMany.filled(["count": String(waiting)]))
            } else {
                lines.append(NeedsYouCopy.offlineBodyNone.text)
            }
            if credential != nil { lines.append(NeedsYouCopy.offlineCause.filled(["account": account])) }
            return lines.joined(separator: " ")
        default: return ""
        }
    }

    /// The buttons an item offers: one for each of its own choices that has a
    /// route, in the order the item lists them.
    static func buttons(for item: InboxItem) -> [NeedsYouButton] {
        guard isShown(item.kind) else { return [] }
        return item.choices.compactMap { choice in
            let kind = item.kind
            switch choice {
            case .signInAgain where kind == .accountSignedOut:
                return NeedsYouButton(action: .signInAgain, label: NeedsYouCopy.signInAgain.text)
            case .allowAnotherRound where kind == .pastRoundLimit:
                return NeedsYouButton(action: .allowAnotherTry, label: NeedsYouCopy.letItTryOnceMore.text)
            case .editContract where [.pastRoundLimit, .refusedForEveryAgent, .checkPastRerunLimit].contains(kind):
                return NeedsYouButton(action: .changeTask, label: NeedsYouCopy.changeTask.text)
            case .cancel where [.pastRoundLimit, .refusedForEveryAgent, .checkPastRerunLimit].contains(kind):
                return NeedsYouButton(action: .cancelTask, label: NeedsYouCopy.cancelTask.text)
            case .overrideOnce where [.refusedForEveryAgent, .checkPastRerunLimit, .checkCouldNotRun].contains(kind):
                return NeedsYouButton(action: .letThroughOnce, label: NeedsYouCopy.letThroughOnce.text)
            case .runAgain where kind == .checkCouldNotRun:
                return NeedsYouButton(action: .runAgain, label: NeedsYouCopy.runAgain.text)
            case .turnRuleOff where [.refusedForEveryAgent, .checkCouldNotRun, .noReviewerEligible].contains(kind):
                return NeedsYouButton(action: .turnRuleOff, label: NeedsYouCopy.turnRuleOff.text)
            case .connectSeat where kind == .noReviewerEligible:
                return NeedsYouButton(action: .connectAgent, label: NeedsYouCopy.connectAgent.text)
            default: return nil
            }
        }
    }

    /// The heading of a notification sent from an event alone, when the item
    /// itself is gone.
    static func settledHeading(kind: NeedsYouItem?) -> String {
        switch kind {
        case .accountSignedOut: NeedsYouCopy.kindSignedOut.text
        case .limitWithNoResetTime: NeedsYouCopy.kindLimit.text
        case .pastRoundLimit: NeedsYouCopy.kindSentBack.text
        case .refusedForEveryAgent: NeedsYouCopy.refusedHeading.text
        case .checkPastRerunLimit: NeedsYouCopy.rerunHeading.text
        case .checkCouldNotRun: NeedsYouCopy.couldNotRunHeading.text
        case .noReviewerEligible: NeedsYouCopy.noReviewerHeading.text
        case .orchestratorOffline: NeedsYouCopy.offlineHeading.text
        default: NeedsYouCopy.kindOther.text
        }
    }

    private static func sentBack(_ item: InboxItem) -> Int {
        guard case .number(let value)? = item.facts["round"] else { return 0 }
        return Int(value)
    }
}
