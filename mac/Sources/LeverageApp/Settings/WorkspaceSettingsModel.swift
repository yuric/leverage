import Foundation
import LeverageKit
import Observation

/// Settings for the workspace (AP-37 to AP-39). The draft keeps the owner's
/// edits when the event feed brings in changes to other fields.
@MainActor
@Observable
final class WorkspaceSettingsModel {
    enum Field: CaseIterable {
        case leaseLength, checkQueueTimeout, checkRunTimeout, maximumRounds, rerunLimit, recoveryTimeCeiling

        var bounds: ClosedRange<Int> {
            switch self {
            case .leaseLength: 300...86400
            case .checkQueueTimeout: 30...3600
            case .checkRunTimeout: 60...3600
            case .maximumRounds, .rerunLimit: 1...20
            case .recoveryTimeCeiling: 60...86400
            }
        }
    }

    enum State: Equatable {
        case loading
        case loaded
        case failed(ShellCopy)
        case signedOut
    }

    private(set) var state: State = .loading
    private(set) var isSaving = false
    var fields: [Field: String] = [:]
    private var baseline: WorkspaceSettings?

    @ObservationIgnored private let api: any OwnerAPI
    @ObservationIgnored private var subscription: EventFeed.Subscription?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAfterSave = false
    @ObservationIgnored private var lastSave: (request: ChangeWorkspaceSettingsRequest, key: IdempotencyKey)?

    init(api: any OwnerAPI) {
        self.api = api
    }

    var hasLoaded: Bool { baseline != nil }
    var canSave: Bool { !isSaving && state != .signedOut && request != nil }

    func load() async {
        guard !isSaving else {
            readAfterSave = true
            return
        }
        generation += 1
        let mine = generation
        reading = true
        defer { if mine == generation { reading = false } }
        do {
            let latest = try await api.workspaceSettings()
            guard mine == generation, !Task.isCancelled else { return }
            apply(latest, replacing: baseline.map(Self.formFields) ?? [:])
        } catch {
            if mine == generation { show(error) }
        }
    }

    func save() async {
        guard !isSaving, state != .signedOut, let request else { return }
        let submittedFields = fields
        isSaving = true
        // A read begun before this command might return older settings.
        readAfterSave = reading
        reading = false
        generation += 1
        let retryKey = lastSave.flatMap { $0.request == request ? $0.key : nil }
        let key = retryKey ?? IdempotencyKey()
        lastSave = (request, key)
        do {
            let outcome = try await api.changeWorkspaceSettings(request, key: key)
            if let updated = try outcome.completedResult() {
                apply(updated, replacing: submittedFields)
            } else {
                readAfterSave = true
            }
            // The server may have replayed the result from before a later change.
            if retryKey != nil { readAfterSave = true }
            lastSave = nil
        } catch {
            if !IdempotencyKey.isKept(after: error) { lastSave = nil }
            show(error)
        }
        let refresh = readAfterSave
        readAfterSave = false
        isSaving = false
        if refresh, state != .signedOut { await load() }
    }

    func attach(to feed: EventFeed) {
        subscription?.cancel()
        subscription = feed.subscribe { [weak self] events in
            guard events.contains(where: { $0.type == .workspaceSettingsChanged }) else { return }
            Task { await self?.load() }
        }
    }

    func detach() {
        subscription?.cancel()
        subscription = nil
    }

    private static func formFields(_ settings: WorkspaceSettings) -> [Field: String] {
        [
            .leaseLength: String(settings.leaseLengthSeconds),
            .checkQueueTimeout: String(settings.checkQueueTimeoutSeconds),
            .checkRunTimeout: String(settings.checkRunTimeoutSeconds),
            .maximumRounds: String(settings.maximumRounds),
            .rerunLimit: String(settings.rerunLimit),
            .recoveryTimeCeiling: settings.recoveryTimeCeilingSeconds.map { String($0) } ?? "",
        ]
    }

    private func apply(_ settings: WorkspaceSettings, replacing previous: [Field: String]) {
        for (field, text) in Self.formFields(settings) where fields[field] == previous[field] {
            fields[field] = text
        }
        baseline = settings
        state = .loaded
    }

    private func show(_ error: any Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if (error as? TransportError)?.code == .unauthenticated {
            state = .signedOut
        } else {
            state = .failed(ShellCopy.sentence(for: error))
        }
    }

    private func text(_ field: Field) -> String {
        fields[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isValid(_ field: Field) -> Bool {
        let input = text(field)
        if field == .recoveryTimeCeiling, input.isEmpty { return true }
        return Int(input).map(field.bounds.contains) ?? false
    }

    private var request: ChangeWorkspaceSettingsRequest? {
        guard let baseline, Field.allCases.allSatisfy(isValid) else { return nil }
        func changed(_ field: Field, from previous: Int) -> Int? {
            let current = Int(text(field))
            return current == previous ? nil : current
        }
        let ceiling = Int(text(.recoveryTimeCeiling))
        let recovery: Setting<Int> = ceiling == baseline.recoveryTimeCeilingSeconds
            ? .keep : ceiling.map(Setting.set) ?? .clear
        let update = ChangeWorkspaceSettingsRequest(
            leaseLengthSeconds: changed(.leaseLength, from: baseline.leaseLengthSeconds),
            checkQueueTimeoutSeconds: changed(.checkQueueTimeout, from: baseline.checkQueueTimeoutSeconds),
            checkRunTimeoutSeconds: changed(.checkRunTimeout, from: baseline.checkRunTimeoutSeconds),
            maximumRounds: changed(.maximumRounds, from: baseline.maximumRounds),
            rerunLimit: changed(.rerunLimit, from: baseline.rerunLimit),
            recoveryTimeCeilingSeconds: recovery)
        return update == ChangeWorkspaceSettingsRequest() ? nil : update
    }
}
