import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Activity")
struct ActivityModelTests {
    @Test("Important uses the registry and Everything keeps all events, newest first with their times")
    func filters() async {
        let events = EventType.allCases.enumerated().map { index, type in Self.event(index + 1, type: type) }
        let server = Server(events: events)
        let model = ActivityModel(api: server.api)
        await model.load()

        let important = Set(ContractLists.importantEventTypes)
        let expected = events.reversed().filter { important.contains($0.type) }
        #expect(model.entries.map(\.seq) == expected.map(\.seq))
        #expect(model.entries.map(\.at) == expected.map(\.at))
        model.filter = .everything
        #expect(model.entries.map(\.seq) == events.reversed().map(\.seq))
        #expect(model.entries.map(\.at) == events.reversed().map(\.at))
        #expect(server.windows.value == [0])
        #expect(!model.hasEarlier)
    }

    @Test("a board watermark anchors the first 500 and earlier windows meet without gaps or duplicates")
    func windows() async {
        let server = Server(events: (1...1040).map { Self.event($0) })
        let model = ActivityModel(api: server.api)
        await model.load()
        #expect(model.entries.map(\.seq) == Array((541...1040).reversed()))
        #expect(model.hasEarlier)

        await model.showEarlier()
        #expect(model.entries.map(\.seq) == Array((41...1040).reversed()))
        #expect(model.hasEarlier)

        await model.showEarlier()
        #expect(model.entries.map(\.seq) == Array((1...1040).reversed()))
        #expect(!model.hasEarlier)
        await model.showEarlier()
        #expect(server.windows.value == [540, 40, 0])
        #expect(server.windowLimits.value == [500, 500, 500])
    }

    @Test("the first window is bounded by its board watermark even when a newer event is already on the server")
    func initialWindowHasAnUpperBound() async {
        let server = Server(events: (1...12).map { Self.event($0) }, boardSeq: 10)
        let model = ActivityModel(api: server.api)
        await model.load()
        #expect(model.entries.map(\.seq) == Array((1...10).reversed()))
        #expect(server.windows.value == [0])
        #expect(!model.hasEarlier)
    }

    @Test("loading an earlier window preserves the shared live tail and ignores a replay below the anchor")
    func keepsLiveTailWhilePaging() async throws {
        let server = Server(events: (1...510).map { Self.event($0) })
        let earlierRequested = Locked(false)
        let allowEarlier = Locked(false)
        let live = Locked(false)
        let events = server.events
        server.api.script {
            $0.events = { after, limit, wait in
                if wait != nil {
                    try await ShellFixtures.waitForActivity { live.value && after < 511 }
                    return Self.page(events + [Self.event(511)], after: after, limit: limit)
                }
                if after == 0 {
                    earlierRequested.update { $0 = true }
                    try await ShellFixtures.waitForActivity { allowEarlier.value }
                }
                return Self.page(events, after: after, limit: limit)
            }
        }
        let feed = EventFeed(owner: server.api)
        let model = ActivityModel(api: server.api)
        model.attach(to: feed)
        defer { model.detach(); feed.stop() }
        await model.load()
        try #require(model.hasEarlier)
        let earlier = Task { await model.showEarlier() }
        defer { earlier.cancel() }

        try #require(await ShellFixtures.eventually { earlierRequested.value })
        feed.noteRead(asOfSeq: 9)
        live.update { $0 = true }
        try #require(await ShellFixtures.eventually { model.entries.first?.seq == 511 })
        #expect(model.entries.map(\.seq) == Array((11...511).reversed()))
        allowEarlier.update { $0 = true }
        await earlier.value

        #expect(model.entries.map(\.seq) == Array((1...511).reversed()))
        #expect(!model.hasEarlier)
    }

    @Test("task rows use TaskLog words, prefix the current title and forget a deleted title")
    func taskTitles() async throws {
        let named = UUID()
        let deleted = UUID()
        let events = [
            Self.event(1, taskID: named),
            Self.event(2, taskID: deleted),
            Self.event(3, taskID: deleted, type: .contentDeleted),
            Self.event(4, type: .workspaceSettingsChanged),
        ]
        let server = Server(events: events, tasks: [
            BoardTask(task: TaskSummary(id: named, title: "Send the report", goal: "", state: .done)),
            BoardTask(task: TaskSummary(id: deleted, title: "", goal: "", state: .done)),
        ])
        let model = ActivityModel(api: server.api)
        await model.load()

        let sentences = Dictionary(uniqueKeysWithValues:
            TaskLog.entries(events: events, names: [], criteria: []).map { ($0.seq, $0.text) })
        let actual = Dictionary(uniqueKeysWithValues: model.entries.map { ($0.seq, $0.text) })
        let namedSentence = try #require(sentences[1])
        let oldSentence = try #require(sentences[2])
        let deletedSentence = try #require(sentences[3])
        #expect(actual[1] == "Send the report: " + namedSentence)
        #expect(actual[2] == "a deleted task: " + oldSentence)
        #expect(actual[3] == "a deleted task: " + deletedSentence)
        #expect(actual[4] == sentences[4])
    }

    private nonisolated static func event(
        _ seq: Int, taskID: UUID? = nil, type: EventType = .taskCreated
    ) -> EventRecord {
        EventRecord(id: UUID(), workspaceID: UUID(), seq: seq, at: Date(timeIntervalSinceReferenceDate: Double(seq)),
                    type: type, actorKind: .owner, taskID: taskID)
    }

    private nonisolated static func page(_ events: [EventRecord], after: Int, limit: Int?) -> EventsPage {
        let window = Array(events.lazy.filter { $0.seq > after }.prefix(limit ?? 100))
        return EventsPage(events: window, nextAfterSeq: window.last?.seq ?? after)
    }

    private struct Server {
        let api = FakeOwnerAPI()
        let events: [EventRecord]
        let windows = Locked<[Int]>([])
        let windowLimits = Locked<[Int?]>([])

        init(events: [EventRecord], boardSeq: Int? = nil, tasks: [BoardTask] = []) {
            self.events = events
            let asOf = boardSeq ?? events.last?.seq ?? 0
            let windows = windows
            let windowLimits = windowLimits
            api.script {
                $0.board = { Board(tasks: tasks, asOfSeq: asOf, reviewerSeatExists: false) }
                $0.seats = { SeatsList(seats: [], asOfSeq: asOf) }
                $0.events = { after, limit, _ in
                    windows.update { $0.append(after) }
                    windowLimits.update { $0.append(limit) }
                    return ActivityModelTests.page(events, after: after, limit: limit)
                }
            }
        }
    }
}

private extension ShellFixtures {
    static func waitForActivity(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + Patience.scaled(.seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
