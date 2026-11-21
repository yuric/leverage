import Foundation
import LeverageKit

/// What the Needs you rows and the notifications name: the task titles and the
/// accounts, from the board and the credentials reads. Never an email.
struct NeedsYouNames: Sendable {
    var tasks: [UUID: String] = [:]
    var credentials: [UUID: Credential] = [:]
    var pages: [UUID: TaskPage] = [:]
    var seats: [UUID: Seat] = [:]
    var projects: [UUID: Project] = [:]
    /// Whether an agent is set up to check tasks: false only when the health
    /// read says none is (`not_set_up`), so the offline item does not talk
    /// of an agent coming back (review finding 27).
    var orchestratorSetUp = true
    /// The clock a reset time is written with.
    var clock: ResetClock = .system

    /// The task's title, or "A task" when the board did not say.
    func taskTitle(_ id: UUID?) -> String {
        id.flatMap { pages[$0]?.task.title ?? tasks[$0] } ?? NeedsYouCopy.aTask.text
    }

    /// "Claude, Personal": the provider and the name, never the email.
    func accountName(_ id: UUID?) -> String {
        guard let credential = id.flatMap({ credentials[$0] }) else { return NeedsYouCopy.anAccount.text }
        return "\(ProviderNames.name(credential.provider)), \(credential.name)"
    }

    func provider(of id: UUID?) -> Provider? { id.flatMap { credentials[$0]?.provider } }

    /// The sentence that names the account the Orchestrator offline item
    /// says is the cause, with what holds it back (L401): signed out, at its
    /// limit until a time, or, when neither is known, the account alone.
    func offlineCause(_ id: UUID) -> String {
        let account = accountName(id)
        guard let credential = credentials[id] else { return NeedsYouCopy.offlineCause.filled(["account": account]) }
        if credential.state == .signedOut { return NeedsYouCopy.offlineCauseSignedOut.filled(["account": account]) }
        if credential.isLimited(at: clock.now()), let until = credential.limitedUntil {
            return NeedsYouCopy.offlineCauseLimitUntil.filled(
                ["account": account, "time": ResetTime.text(for: until, clock: clock)])
        }
        return NeedsYouCopy.offlineCause.filled(["account": account])
    }

    /// The names, and whether an agent is set up to check tasks when one of
    /// the items is the Orchestrator offline item (read from the health
    /// line only then; a read that fails keeps the "is back" wording).
    func checkingOrchestrator(for items: [InboxItem], from owner: any OwnerAPI) async -> NeedsYouNames {
        guard items.contains(where: { $0.kind == .orchestratorOffline }) else { return self }
        var names = self
        if let health = try? await owner.systemHealth() { names.orchestratorSetUp = health.orchestrator != .notSetUp }
        return names
    }

    func page(for item: InboxItem) -> TaskPage? {
        NeedsYouWords.taskID(of: item).flatMap { pages[$0] }
    }

    func seatName(_ id: UUID?, on page: TaskPage?) -> String? {
        guard let id else { return nil }
        return seats[id]?.name ?? page?.names.first { $0.kind == .seat && $0.id == id }?.name
    }

    /// The inbox facts identify the subjects, and the owner reads supply their
    /// content and the original builder's current availability.
    func addingDetails(for items: [InboxItem], from owner: any OwnerAPI) async throws -> NeedsYouNames {
        var names = self
        let taskIDs = Set(items.filter { NeedsYouWords.needsTaskPage($0.kind) }.compactMap(NeedsYouWords.taskID))
        for id in taskIDs {
            names.pages[id] = try await Self.available { try await owner.task(id: id) }
        }
        if items.contains(where: { [.questionPassedOn, .unconfirmedAction, .accessRequest].contains($0.kind) }),
           let list = try await Self.available({ try await owner.seats() }) {
            for seat in list.seats { names.seats[seat.id] = seat }
        }
        if items.contains(where: { $0.kind == .projectBudgetReached }),
           let list = try await Self.available({ try await owner.listProjects() }) {
            for project in list.projects { names.projects[project.id] = project }
        }
        return names
    }

    private static func available<T: Sendable>(_ read: () async throws -> T) async throws -> T? {
        do {
            return try await read()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch let error as TransportError where error.code == .unauthenticated {
            throw error
        } catch {
            return nil
        }
    }

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
    enum Action: Hashable, Sendable {
        case signInAgain, allowAnotherTry, changeTask, cancelTask
        case letThroughOnce, runAgain, turnRuleOff, connectAgent
        case keepAssumption, answerDifferently, approve, stop, returnForRework, offerAgain
        case markDone(UUID), waive(UUID)
        case grantAccess, raiseCap, changeBudget, resumeProject
    }

    let action: Action
    let label: String
    var id: Action { action }
}

/// The words of each item kind (HM-24), shared by the screen and the notifier.
enum NeedsYouWords {
    /// Every current contract kind has a route for its choices (HM-21).
    static func isShown(_ kind: NeedsYouItem) -> Bool {
        switch kind {
        case .accountSignedOut, .limitWithNoResetTime, .pastRoundLimit: true
        case .refusedForEveryAgent, .checkPastRerunLimit, .checkCouldNotRun, .noReviewerEligible,
            .orchestratorOffline: true
        case .questionPassedOn, .approval, .stoppedAction, .unconfirmedAction, .accessRequest,
            .taskBudgetReached, .projectBudgetReached: true
        }
    }

    static func needsTaskPage(_ kind: NeedsYouItem) -> Bool {
        switch kind {
        case .questionPassedOn, .approval, .stoppedAction, .unconfirmedAction, .accessRequest, .taskBudgetReached:
            true
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
        case .questionPassedOn:
            let page = names.page(for: item)
            let agent = agentName(question(in: item, page: page)?.askingSeatID, page: page, names: names)
            return NeedsYouCopy.questionHeading.filled(["task": task, "agent": agent])
        case .approval:
            guard let action = action(in: item, page: names.page(for: item)) else {
                return NeedsYouCopy.kindApproval.text
            }
            return NeedsYouCopy.approvalHeading.filled(["action": actionPhrase(action)])
        case .stoppedAction:
            guard let action = action(in: item, page: names.page(for: item)) else { return settledHeading(kind: .stoppedAction) }
            return NeedsYouCopy.stoppedHeading.filled(["verb": verb(action.kind)])
        case .unconfirmedAction:
            guard let action = unconfirmed(in: item, page: names.page(for: item)).first else {
                return settledHeading(kind: .unconfirmedAction)
            }
            return NeedsYouCopy.unconfirmedHeading.filled(["action": activity(action.kind).lowercased()])
        case .accessRequest:
            let page = names.page(for: item)
            return NeedsYouCopy.accessHeading.filled([
                "agent": agentName(page?.task.holderSeatID ?? page?.task.builderSeatID, page: page, names: names)
            ])
        case .taskBudgetReached:
            return NeedsYouCopy.taskBudgetHeading.filled(["task": task])
        case .projectBudgetReached:
            let project = names.projects[item.aboutID]?.name ?? NeedsYouCopy.aProject.text
            return NeedsYouCopy.projectBudgetHeading.filled(["project": project])
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
            guard names.orchestratorSetUp else { return NeedsYouCopy.offlineBodyNotSetUp.text }
            let waiting = item.waitingChecks ?? 0
            var lines: [String] = []
            if waiting == 1 {
                lines.append(NeedsYouCopy.offlineBodyOne.filled(["count": "1"]))
            } else if waiting > 1 {
                lines.append(NeedsYouCopy.offlineBodyMany.filled(["count": String(waiting)]))
            } else {
                lines.append(NeedsYouCopy.offlineBodyNone.text)
            }
            if let credential { lines.append(names.offlineCause(credential)) }
            return lines.joined(separator: " ")
        case .questionPassedOn:
            guard let question = question(in: item, page: names.page(for: item)) else {
                return NeedsYouCopy.detailsUnavailable.text
            }
            if question.blocking {
                let assumption = NeedsYouCopy.questionAssumption.filled(["assumption": question.assumption])
                return [question.text, assumption, NeedsYouCopy.questionWaiting.text].joined(separator: "\n")
            }
            let assumption = NeedsYouCopy.questionAssuming.filled(["assumption": question.assumption])
            return "\(question.text)\n\(assumption)"
        case .approval:
            guard let action = action(in: item, page: names.page(for: item)) else {
                return NeedsYouCopy.detailsUnavailable.text
            }
            return NeedsYouCopy.approvalBody.filled(["task": task, "action": activity(action.kind)])
        case .stoppedAction:
            let page = names.page(for: item)
            let cause = stoppedCause(for: item, page: page, names: names)
            return hasStarted(item, page: page) ? "\(cause) \(NeedsYouCopy.startedWarning.text)" : cause
        case .unconfirmedAction:
            let page = names.page(for: item)
            let actions = unconfirmed(in: item, page: page)
            if actions.isEmpty { return NeedsYouCopy.detailsUnavailable.text }
            return actions.map { unconfirmedLine($0, item: item, page: page, names: names) }.joined(separator: "\n")
        case .accessRequest:
            return item.detail ?? NeedsYouCopy.accessBody.text
        case .taskBudgetReached:
            return names.page(for: item).map { reported($0.task.spent) } ?? ""
        case .projectBudgetReached:
            return names.projects[item.aboutID].map { reported($0.spent) } ?? ""
        }
    }

    /// The buttons an item offers: one for each of its own choices that has a
    /// route, in the order the item lists them.
    static func buttons(for item: InboxItem, names: NeedsYouNames) -> [NeedsYouButton] {
        guard isShown(item.kind) else { return [] }
        let kind = item.kind
        if needsTaskPage(kind) || kind == .projectBudgetReached {
            return milestoneFiveButtons(for: item, names: names)
        }
        return item.choices.compactMap { choice in
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

    private static func milestoneFiveButtons(for item: InboxItem, names: NeedsYouNames) -> [NeedsYouButton] {
        let page = names.page(for: item)
        let action = action(in: item, page: page)
        return item.choices.flatMap { choice -> [NeedsYouButton] in
            switch (item.kind, choice) {
            case (.questionPassedOn, .answer):
                guard let question = question(in: item, page: page) else { return [] }
                let different = button(.answerDifferently, .answerDifferently)
                return question.assumption.isEmpty ? [different] : [button(.keepAssumption, .keepAssumption), different]
            case (.approval, .approve) where action?.state == .requested:
                return [button(.approve, .approve)]
            case (.approval, .stop):
                guard let action, action.state == .requested else { return [] }
                return [NeedsYouButton(action: .stop, label: NeedsYouCopy.stop.filled([
                    "verb": verb(action.kind).lowercased()
                ]))]
            case (.stoppedAction, .waive):
                guard let id = item.actionID else { return [] }
                return [button(.waive(id), .waive)]
            case (.stoppedAction, .returnForRework) where item.anyActionStarted == false && page?.anyActionStarted == false:
                return [button(.returnForRework, .returnForRework)]
            case (.stoppedAction, .overrideOnce) where item.ruleCheckID != nil:
                return [button(.letThroughOnce, .letThroughOnce)]
            case (.unconfirmedAction, .offerAgain):
                guard let id = page?.task.builderSeatID, let builder = names.seats[id],
                      builder.enabled, builder.removedAt == nil
                else { return [] }
                return [NeedsYouButton(action: .offerAgain, label: NeedsYouCopy.offerAgain.filled(["agent": builder.name]))]
            case (.unconfirmedAction, .markDone), (.unconfirmedAction, .waive):
                let actions = unconfirmed(in: item, page: page)
                return actions.map { action in
                    let mark = choice == .markDone
                    let copy = mark ? NeedsYouCopy.markDone : .waive
                    let label = actions.count > 1 ? NeedsYouCopy.actionChoice.filled([
                        "choice": copy.text, "description": action.description,
                    ]) : copy.text
                    return NeedsYouButton(action: mark ? .markDone(action.id) : .waive(action.id), label: label)
                }
            case (.accessRequest, .markAccessGranted):
                return [button(.grantAccess, .grantAccess)]
            case (.taskBudgetReached, .raiseCap):
                return [button(.raiseCap, .raiseCap)]
            case (.projectBudgetReached, .changeBudget):
                return [button(.changeBudget, .changeBudget)]
            case (.projectBudgetReached, .resumeProject):
                return [button(.resumeProject, .resumeProject)]
            case (.stoppedAction, .cancel), (.unconfirmedAction, .cancel), (.accessRequest, .cancel),
                (.taskBudgetReached, .cancel):
                return [button(.cancelTask, .cancelTask)]
            default:
                return []
            }
        }
    }

    private static func button(_ action: NeedsYouButton.Action, _ copy: NeedsYouCopy) -> NeedsYouButton {
        NeedsYouButton(action: action, label: copy.text)
    }

    static func question(in item: InboxItem, page: TaskPage?) -> Question? {
        page?.questions.first { $0.id == item.questionID }
    }

    private static func action(in item: InboxItem, page: TaskPage?) -> OutwardAction? {
        page?.actions.first { $0.id == item.actionID }
    }

    private static func unconfirmed(in item: InboxItem, page: TaskPage?) -> [OutwardAction] {
        let ids = Set(item.actionIDs)
        return page?.actions.filter { ids.contains($0.id) && ($0.state == .approved || $0.state == .started) } ?? []
    }

    private static func agentName(_ id: UUID?, page: TaskPage?, names: NeedsYouNames) -> String {
        names.seatName(id, on: page) ?? NeedsYouCopy.anAgent.text
    }

    private static func unconfirmedLine(
        _ action: OutwardAction, item: InboxItem, page: TaskPage?, names: NeedsYouNames
    ) -> String {
        // The current action and its events distinguish individual actions.
        // The item's approval and start facts describe the first action.
        let first = item.actionIDs.first == action.id
        let kind = action.approvedByKind ?? (first ? item.approvedByKind : nil)
        let id = action.approvedByID ?? (first ? item.approvedByID : nil)
        let approver = kind == .owner ? NeedsYouCopy.approvedByYou.text
            : names.seatName(id, on: page) ?? NeedsYouCopy.approvalUnknown.text
        let announced = action.state == .started
            || page?.events.contains(where: { $0.type == .actionStarted && $0.subjectID == action.id }) == true
        let started = announced ? true : (first ? item.builderAnnouncedStart : false)
        let when: NeedsYouCopy = switch started {
        case true?: .unconfirmedAfterStart
        case false?: .unconfirmedBeforeStart
        case nil: .unconfirmedStartUnknown
        }
        return NeedsYouCopy.unconfirmedBody.filled([
            "agent": agentName(page?.task.builderSeatID, page: page, names: names),
            "action": actionPhrase(action, lowercaseVerb: true),
            "who": approver, "when": when.text,
        ])
    }

    private static func actionPhrase(_ action: OutwardAction, lowercaseVerb: Bool = false) -> String {
        let verb = verb(action.kind)
        var detail = action.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = detail.range(
            of: "^" + NSRegularExpression.escapedPattern(for: verb) + #"\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            detail.removeSubrange(prefix)
        }
        detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = detail.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        let title = lowercaseVerb ? verb.lowercased() : verb
        return detail.isEmpty ? title : title + " " + detail
    }

    private static func stoppedCause(for item: InboxItem, page: TaskPage?, names: NeedsYouNames) -> String {
        if item.ruleCheckID != nil { return NeedsYouCopy.ruleStoppedAction.text }
        guard let id = item.actionID,
              let event = page?.events.last(where: { $0.type == .actionStopped && $0.subjectID == id })
        else { return NeedsYouCopy.stoppedBody.text }
        if event.actorKind == .owner { return NeedsYouCopy.ownerStoppedAction.text }
        if event.actorKind == .seat {
            return NeedsYouCopy.agentStoppedAction.filled(["agent": agentName(event.actorID, page: page, names: names)])
        }
        return NeedsYouCopy.stoppedBody.text
    }

    static func hasStarted(_ item: InboxItem, page: TaskPage?) -> Bool {
        page?.anyActionStarted == true || item.anyActionStarted == true || item.builderAnnouncedStart == true
    }

    private static func reported(_ amount: Decimal) -> String {
        NeedsYouCopy.reportedAmount.filled([
            "amount": amount.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        ])
    }

    private static func verb(_ kind: ActionKind) -> String {
        switch kind {
        case .publish: NeedsYouCopy.publish.text
        case .pay: NeedsYouCopy.pay.text
        case .send: NeedsYouCopy.send.text
        case .delete: NeedsYouCopy.delete.text
        }
    }

    private static func activity(_ kind: ActionKind) -> String {
        switch kind {
        case .publish: NeedsYouCopy.publishing.text
        case .pay: NeedsYouCopy.paying.text
        case .send: NeedsYouCopy.sending.text
        case .delete: NeedsYouCopy.deleting.text
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
        case .questionPassedOn: NeedsYouCopy.kindQuestion.text
        case .approval: NeedsYouCopy.kindApproval.text
        case .stoppedAction: NeedsYouCopy.kindStopped.text
        case .unconfirmedAction: NeedsYouCopy.kindUnconfirmed.text
        case .accessRequest: NeedsYouCopy.kindAccess.text
        case .taskBudgetReached, .projectBudgetReached: NeedsYouCopy.kindBudget.text
        case nil: NeedsYouCopy.kindOther.text
        }
    }

    private static func sentBack(_ item: InboxItem) -> Int {
        guard case .number(let value)? = item.facts["round"] else { return 0 }
        return Int(value)
    }
}
