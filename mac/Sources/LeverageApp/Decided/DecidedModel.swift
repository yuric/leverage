import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class DecidedModel {
    enum State: Equatable {
        case loading
        case loaded
        case failed(ShellCopy)
    }

    private(set) var state: State = .loading
    private(set) var rows: [Decision] = []
    private(set) var confirming: Decision?
    private(set) var busy = false
    private(set) var failure: ShellCopy?
    private var recordableApprovals: Set<Decision.RowID> = []
    var answer = ""

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var undoKey: IdempotencyKey?
    @ObservationIgnored private var answerKey: IdempotencyKey?
    @ObservationIgnored private var sentAnswer: String?
    @ObservationIgnored private var withdrewAnswer = false

    init(api: any OwnerAPI) {
        self.api = api
    }

    func load() async {
        generation += 1
        let mine = generation
        do {
            let decisions = try await api.listDecisions().decisions.sorted { $0.decidedAt > $1.decidedAt }
            // Overturn approval takes an action id and records against its latest approval.
            let latestApprovals = Dictionary(
                decisions.compactMap { decision -> (UUID, Decision)? in
                    guard decision.kind == .approval, let id = decision.actionID else { return nil }
                    return (id, decision)
                }, uniquingKeysWith: { latest, _ in latest })
            let candidates = latestApprovals.values.filter(isUnrecordedCompletedApproval)
            let taskIDs = Set(candidates.map(\.taskID))
            let tasks = taskIDs.isEmpty ? [] : ((try? await api.board().tasks) ?? [])
            guard mine == generation, !Task.isCancelled else { return }
            // A completed action can still belong to a cancelled task, which
            // has no record-only transition. The board includes those tasks.
            let allowedTasks = Set<UUID>(tasks.compactMap { row in
                let task = row.task
                return task.state == .finishing || task.state == .done ? task.id : nil
            })
            recordableApprovals = Set(candidates.filter { allowedTasks.contains($0.taskID) }.map(\.decidedRowID))
            rows = decisions
            if let confirming, confirming.kind == .approval, !busy {
                if let current = actionableDecision(confirming.decidedRowID) {
                    self.confirming = current
                } else {
                    clearConfirmation()
                }
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    func watch(using feed: EventFeed) async {
        let (updates, request) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = feed.subscribe { events in
            if events.contains(where: Self.affectsDecisions) { request.yield() }
        }
        defer {
            subscription.cancel()
            request.finish()
        }

        // The decisions read has no log position. If no screen has started
        // the feed, seed it with a position obtained before reading decisions.
        if feed.connection == .idle, let position = try? await api.board().asOfSeq, !Task.isCancelled {
            feed.noteRead(asOfSeq: position)
        }
        request.yield()
        for await _ in updates {
            await load()
        }
    }

    nonisolated private static func affectsDecisions(_ event: EventRecord) -> Bool {
        switch event.type {
        case .questionAnswered, .questionOverturned, .actionApproved, .actionStarted, .actionStopped,
            .actionReportedDone, .actionMarkedDone, .actionWaived, .actionWithdrawn, .actionRevoked,
            .actionOverturnRecorded, .taskChanged, .taskDone, .taskCancelled, .contentDeleted:
            true
        default:
            false
        }
    }

    func requestUndo(_ decision: Decision) {
        guard !busy, confirming == nil,
              let current = actionableDecision(decision.decidedRowID) else { return }
        confirming = current
    }

    private func actionableDecision(_ id: Decision.RowID) -> Decision? {
        rows.first { $0.decidedRowID == id && (canUndo($0) || canRecordObjection($0)) }
    }

    func canUndo(_ decision: Decision) -> Bool {
        guard decision.undoable, decision.overturnedAt == nil, decision.overturnEffect == nil else { return false }
        switch decision.kind {
        case .question: return decision.questionID != nil
        case .approval: return decision.actionID != nil && decision.actionState != .done
        }
    }

    func canRecordObjection(_ decision: Decision) -> Bool {
        recordableApprovals.contains(decision.decidedRowID)
    }

    private func isUnrecordedCompletedApproval(_ decision: Decision) -> Bool {
        decision.kind == .approval && decision.actionID != nil && decision.actionState == .done
            && decision.overturnedAt == nil && decision.overturnEffect == nil
    }

    func dismissUndo() {
        guard !busy else { return }
        clearConfirmation()
    }

    var canEditAnswer: Bool { !busy && sentAnswer == nil && undoKey == nil }

    func confirmUndo() async {
        guard let selected = confirming, !busy else { return }
        let decision: Decision
        if selected.kind == .approval {
            guard let current = actionableDecision(selected.decidedRowID) else {
                clearConfirmation()
                return
            }
            decision = current
        } else {
            decision = selected
        }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            if !withdrewAnswer {
                let key = undoKey ?? IdempotencyKey()
                undoKey = key
                switch decision.kind {
                case .question:
                    guard let id = decision.questionID else { return }
                    _ = try await api.overturnAnswer(questionID: id, key: key).completedResult()
                    withdrewAnswer = true
                case .approval:
                    guard let id = decision.actionID else { return }
                    _ = try await api.overturnApproval(actionID: id, key: key).completedResult()
                }
                undoKey = nil
            }

            if decision.kind == .question, let id = decision.questionID {
                let replacement = sentAnswer ?? answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !replacement.isEmpty {
                    let key = answerKey ?? IdempotencyKey()
                    answerKey = key
                    sentAnswer = replacement
                    _ = try await api.answerQuestion(
                        questionID: id, AnswerQuestionRequest(answer: replacement), key: key
                    ).completedResult()
                }
            }

            clearConfirmation()
            await load()
        } catch is CancellationError {
            return
        } catch {
            if CommandKey.wasAnswered(error) {
                undoKey = nil
                answerKey = nil
                sentAnswer = nil
            }
            failure = ShellCopy.sentence(for: error)
            if withdrewAnswer { await load() }
        }
    }

    private func clearConfirmation() {
        confirming = nil
        answer = ""
        failure = nil
        undoKey = nil
        answerKey = nil
        sentAnswer = nil
        withdrewAnswer = false
    }

    func mark(for decision: Decision) -> String {
        if !canUndo(decision) { return DecidedCopy.cannotUndo.text }
        if decision.kind == .approval && decision.started { return DecidedCopy.mayHaveGoneOut.text }
        return DecidedCopy.canUndo.text
    }

    func effect(for decision: Decision) -> String? {
        switch decision.overturnEffect {
        case .stopped: DecidedCopy.stopped.text
        case .recordedOnly: DecidedCopy.recordedEffect(summary: decision.summary)
        case .answerWithdrawn:
            decision.outcome.map { DecidedCopy.newAnswer.filled(["answer": $0]) } ?? DecidedCopy.noNewAnswer.text
        case nil: nil
        }
    }
}

extension Decision {
    struct RowID: Hashable {
        let kind: DecisionKind
        let subjectID: UUID
        let decidedAt: Date
    }

    var decidedRowID: RowID { RowID(kind: kind, subjectID: questionID ?? actionID ?? taskID, decidedAt: decidedAt) }
}
