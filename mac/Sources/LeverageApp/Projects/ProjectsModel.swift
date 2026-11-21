import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class ProjectsModel {
    enum State: Equatable {
        case loading, loaded
        case failed(ShellCopy)
    }

    enum Change: Equatable {
        case create(CreateProjectRequest)
        case editBrief(UUID, EditBriefRequest)
        case changeBudget(UUID, ChangeBudgetRequest)
        case pause(UUID)
        case resume(UUID)
        case deleteContent(UUID)
    }

    private(set) var projects: [Project] = []
    private(set) var state: State = .loading
    private(set) var failure: ShellCopy?
    private(set) var isSaving = false

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var retry: (change: Change, key: IdempotencyKey)?
    let locale: Locale

    init(api: any OwnerAPI, locale: Locale = .current) {
        self.api = api
        self.locale = locale
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let list = try await api.listProjects()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            projects = list.projects
            state = .loaded
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    /// Refresh the project list once per relevant batch from the shared feed.
    func watch(_ feed: EventFeed) async {
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = feed.subscribe { events in
            if events.contains(where: Self.affectsProjects) { continuation.yield() }
        }
        defer {
            subscription.cancel()
            continuation.finish()
        }

        // ProjectsList has no watermark. Take a position before reading the list.
        if feed.connection == .idle, let position = try? await api.seats().asOfSeq, !Task.isCancelled {
            feed.noteRead(asOfSeq: position)
        }
        continuation.yield()
        for await _ in updates {
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private static func affectsProjects(_ event: EventRecord) -> Bool {
        switch event.type {
        case .projectCreated, .projectBudgetChanged, .projectPaused, .projectResumed, .briefChanged,
            .costReported, .taskCreated, .taskChanged, .taskDone, .taskCancelled, .contentDeleted:
            return true
        default:
            return false
        }
    }

    func clearFailure() { failure = nil }

    func canCreate(name: String, budget: String) -> Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && budgetRequest(budget) != nil
    }

    func create(name: String, goal: String, budget: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let amount = budgetRequest(budget) else { return false }
        return await save(.create(CreateProjectRequest(
            name: name, goal: goal.isEmpty ? nil : goal, budget: amount.budget)))
    }

    /// Empty clears the limit. Require the whole field to be a number so
    /// an input such as "20.00 extra" cannot be sent as a budget of 20.
    func budgetRequest(_ input: String) -> ChangeBudgetRequest? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return ChangeBudgetRequest(budget: nil) }
        let separator = NSRegularExpression.escapedPattern(for: locale.decimalSeparator ?? ".")
        let pattern = #"^[0-9]+(?:\#(separator)[0-9]{1,2})?$"#
        guard input.range(of: pattern, options: .regularExpression) != nil,
              let number = Decimal(string: input, locale: locale)
        else { return nil }
        return ChangeBudgetRequest(budget: number)
    }

    func save(_ change: Change) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        failure = nil
        defer { isSaving = false }

        // A lost response may have followed a committed write. Retrying
        // the same request uses the same key until the server answers.
        let key: IdempotencyKey
        if let retry, retry.change == change {
            key = retry.key
        } else {
            key = IdempotencyKey()
        }
        retry = (change, key)
        do {
            let outcome = switch change {
            case .create(let request):
                try await api.createProject(request, key: key)
            case .editBrief(let id, let request):
                try await api.editBrief(projectID: id, request, key: key)
            case .changeBudget(let id, let request):
                try await api.changeBudget(projectID: id, request, key: key)
            case .pause(let id):
                try await api.pauseProject(projectID: id, key: key)
            case .resume(let id):
                try await api.resumeProject(projectID: id, key: key)
            case .deleteContent(let id):
                try await api.deleteProjectContent(projectID: id, key: key)
            }
            if outcome.outcome != .pending { retry = nil }
            _ = try outcome.completedResult()
            await load()
            return true
        } catch {
            if !Task.isCancelled { failure = ShellCopy.sentence(for: error) }
            return false
        }
    }
}
