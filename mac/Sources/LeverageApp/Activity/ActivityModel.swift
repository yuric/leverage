import Foundation
import LeverageKit
import Observation

/// Bounded reads supply Activity's history. The shared EventFeed supplies
/// everything after the first board watermark.
@MainActor
@Observable
final class ActivityModel {
    enum Filter: Hashable {
        case important, everything
    }

    private static let windowSize = 500
    private static let importantTypes = Set(ContractLists.importantEventTypes)

    var filter: Filter = .important
    private(set) var isLoading = false
    private(set) var isLoadingEarlier = false
    private(set) var failure: ShellCopy?

    private var anchor: Int?
    /// How many events precede the oldest loaded history window.
    private var historyStart = 0
    private var events: [Int: EventRecord] = [:]
    private var taskTitles: [UUID: String] = [:]
    private var deletedTasks: Set<UUID> = []
    private var agentNames: [UUID: LogName] = [:]
    private var accountNames: [UUID: String] = [:]

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private weak var feed: EventFeed?
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var namesRefresh: Task<Void, Never>?
    @ObservationIgnored private var agentNamesSeq = 0
    @ObservationIgnored private var accountNamesSeq = 0

    var hasEarlier: Bool { historyStart > 0 }
    var isLoaded: Bool { anchor != nil }

    var entries: [LogEntry] {
        let names = Array(agentNames.values)
        // TaskLog interprets related events within one task, even when the
        // chosen filter hides the events that explain a later sentence.
        let byTask = Dictionary(grouping: events.values, by: \.taskID)
        return byTask.flatMap { taskID, events in
            let log = TaskLog.entries(events: events, names: names, criteria: [], accounts: accountNames)
            let shown = filter == .everything ? log : importantEntries(log, events: events)
            guard let taskID else { return shown }
            let title = title(for: taskID)
            return shown.map {
                LogEntry(id: $0.id, seq: $0.seq, at: $0.at,
                         text: ActivityCopy.taskPrefix.filled(["title": title]) + " " + $0.text)
            }
        }.sorted { $0.seq > $1.seq }
    }

    init(api: any OwnerAPI) {
        self.api = api
    }

    func attach(to feed: EventFeed) {
        detach()
        self.feed = feed
        let (changes, request) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        namesRefresh = Task { [weak self] in
            for await _ in changes {
                await self?.refreshNames()
            }
        }
        subscription = feed.subscribe { [weak self] events in
            if self?.receive(events) == true { request.yield() }
        }
        if let anchor { feed.noteRead(asOfSeq: anchor) }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
        namesRefresh?.cancel()
        namesRefresh = nil
        feed = nil
    }

    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let board = try await api.board()
            try await loadWindow(endingAt: board.asOfSeq)
            storeTitles(from: board)
            anchor = board.asOfSeq
            // If another screen already moved the tail past this watermark
            // while the read was out, EventFeed replays from here.
            feed?.noteRead(asOfSeq: board.asOfSeq)
            await refreshAgentNames()
            await refreshAccountNames()
        } catch {
            report(error)
        }
    }

    func showEarlier() async {
        guard hasEarlier, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        failure = nil
        defer { isLoadingEarlier = false }
        do {
            try await loadWindow(endingAt: historyStart)
        } catch {
            report(error)
        }
    }

    private func loadWindow(endingAt upper: Int) async throws {
        let after = max(0, upper - Self.windowSize)
        let page = try await api.events(afterSeq: after, limit: Self.windowSize, wait: nil)
        try Task.checkCancellation()
        // A short window at the beginning of the log can include events
        // past its upper bound. The next window or the tail owns those.
        for event in page.events where event.seq <= upper {
            store(event)
        }
        historyStart = after
    }

    private func receive(_ batch: [EventRecord]) -> Bool {
        guard let anchor else { return false }
        var namesChanged = false
        for event in batch where event.seq > anchor && events[event.seq] == nil {
            store(event)
            switch event.type {
            case .taskCreated, .taskChanged, .taskContractChanged:
                namesChanged = namesChanged || event.taskID != nil
            case .seatConnected, .seatChanged, .seatRemoved,
                 .credentialAdded, .credentialRenamed, .credentialOrderChanged, .credentialRemoved:
                namesChanged = true
            default:
                break
            }
        }
        return namesChanged
    }

    private func store(_ event: EventRecord) {
        events[event.seq] = event
        if event.type == .contentDeleted, let taskID = event.taskID {
            deletedTasks.insert(taskID)
            taskTitles[taskID] = nil
        }
    }

    private func storeTitles(from board: Board) {
        taskTitles = Dictionary(uniqueKeysWithValues: board.tasks.compactMap { card in
            let task = card.task
            return deletedTasks.contains(task.id) ? nil : (task.id, task.title)
        })
    }

    private func refreshNames() async {
        if let board = try? await api.board(), !Task.isCancelled {
            storeTitles(from: board)
        }
        if !Task.isCancelled { await refreshAgentNames() }
        if !Task.isCancelled { await refreshAccountNames() }
    }

    private func refreshAgentNames() async {
        // A missing name leaves TaskLog's usual plain fallback. Keep names
        // already read when an agent is later removed from the roster.
        guard let seats = try? await api.seats(), !Task.isCancelled, seats.asOfSeq >= agentNamesSeq else { return }
        for seat in seats.seats {
            agentNames[seat.id] = LogName(kind: .seat, id: seat.id, name: seat.name)
        }
        agentNamesSeq = seats.asOfSeq
    }

    private func refreshAccountNames() async {
        guard let rows = try? await api.credentials(), !Task.isCancelled, rows.asOfSeq >= accountNamesSeq else { return }
        accountNames = Dictionary(uniqueKeysWithValues: rows.credentials.map { ($0.credential.id, $0.credential.name) })
        accountNamesSeq = rows.asOfSeq
    }

    private func title(for taskID: UUID) -> String {
        if deletedTasks.contains(taskID) { return ActivityCopy.deletedTask.text }
        guard let title = taskTitles[taskID] else { return ActivityCopy.aTask.text }
        return title.isEmpty ? ActivityCopy.deletedTask.text : title
    }

    private func importantEntries(_ entries: [LogEntry], events: [EventRecord]) -> [LogEntry] {
        let important = Set(events.lazy.filter { Self.importantTypes.contains($0.type) }.map(\.seq))
        return entries.filter { important.contains($0.seq) }
    }

    private func report(_ error: any Error) {
        guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        failure = ShellCopy.sentence(for: error)
    }
}
