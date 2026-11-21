import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Workspace settings (AP-37 to AP-39)")
struct WorkspaceSettingsModelTests {
    private typealias Field = WorkspaceSettingsModel.Field

    private let initial = WorkspaceSettings(
        leaseLengthSeconds: 600, checkQueueTimeoutSeconds: 90, checkRunTimeoutSeconds: 120,
        maximumRounds: 3, rerunLimit: 3, recoveryTimeCeilingSeconds: 3600)

    private func makeOwner() -> FakeOwnerAPI {
        let owner = FakeOwnerAPI()
        let initial = self.initial
        owner.script { $0.workspaceSettings = { initial } }
        return owner
    }

    @Test("Recovery settings name the wait being measured and count failed reviews")
    func settingsCopy() {
        #expect(WorkspaceSettingsCopy.label(for: .maximumRounds).text.contains("failed reviews"))
        #expect(WorkspaceSettingsCopy.label(for: .recoveryTimeCeiling).text.contains("limit or sign-out"))
        #expect(WorkspaceSettingsCopy.hint(for: .recoveryTimeCeiling).contains("measures"))
    }

    @Test("The six saved values are shown, and an untouched form sends no command")
    func readsSettings() async {
        let owner = makeOwner()
        let model = WorkspaceSettingsModel(api: owner)
        await model.load()
        #expect(model.fields == [
            .leaseLength: "600", .checkQueueTimeout: "90", .checkRunTimeout: "120",
            .maximumRounds: "3", .rerunLimit: "3", .recoveryTimeCeiling: "3600",
        ])
        #expect(!model.canSave)
        await model.save()
        #expect(owner.calls.map(\.operation) == [.getWorkspaceSettings])
    }

    @Test("Every field accepts both ends of its range and rejects numbers outside it")
    func bounds() async {
        let owner = makeOwner()
        let model = WorkspaceSettingsModel(api: owner)
        await model.load()
        let fields = model.fields
        let bounds: [(Field, Int, Int)] = [
            (.leaseLength, 300, 86400), (.checkQueueTimeout, 30, 3600), (.checkRunTimeout, 60, 3600),
            (.maximumRounds, 1, 20), (.rerunLimit, 1, 20), (.recoveryTimeCeiling, 60, 86400),
        ]
        for (field, lower, upper) in bounds {
            for value in [String(lower - 1), String(upper + 1), "1.5", "abc", "999999999999999999999"] {
                model.fields[field] = value
                #expect(!model.canSave, "\(field): \(value)")
                await model.save()
            }
            if field != .recoveryTimeCeiling {
                model.fields[field] = ""
                #expect(!model.canSave, "\(field)")
                await model.save()
            }
            for value in [lower, upper] {
                model.fields[field] = String(value)
                #expect(model.canSave, "\(field): \(value)")
            }
            model.fields = fields
        }
        #expect(owner.calls.map(\.operation) == [.getWorkspaceSettings])
    }

    @Test("Save sends only changed fields and clears the recovery ceiling with JSON null")
    func saveChangesAndClearCeiling() async throws {
        let owner = makeOwner()
        let saved = WorkspaceSettings(
            leaseLengthSeconds: 900, checkQueueTimeoutSeconds: 90, checkRunTimeoutSeconds: 120,
            maximumRounds: 3, rerunLimit: 3)
        owner.script {
            $0.changeWorkspaceSettings = { _, key in
                .completed(saved, key: key.value, command: .changeWorkspaceSettings)
            }
        }
        let model = WorkspaceSettingsModel(api: owner)
        await model.load()
        model.fields[.leaseLength] = " 900 "
        model.fields[.recoveryTimeCeiling] = " "
        #expect(model.canSave)
        await model.save()
        let change = try #require(owner.calls.first { $0.operation == .changeWorkspaceSettings })
        #expect(change.body == .object(["lease_length_seconds": .number(900), "recovery_time_ceiling_seconds": .null]))
        #expect(change.key != nil)
        #expect(model.fields[.leaseLength] == "900")
        #expect(model.fields[.recoveryTimeCeiling] == "")
        #expect(!model.canSave)
    }

    @Test("Save sends all six changed settings and retries the same request with the same key")
    func saveAndRetry() async throws {
        let owner = makeOwner()
        let updated = WorkspaceSettings(
            leaseLengthSeconds: 900, checkQueueTimeoutSeconds: 180, checkRunTimeoutSeconds: 200,
            maximumRounds: 5, rerunLimit: 4, recoveryTimeCeilingSeconds: 8000)
        let attempts = Locked(0)
        let settings = Locked(initial)
        owner.script {
            $0.workspaceSettings = { settings.value }
            $0.changeWorkspaceSettings = { _, key in
                if attempts.update({ $0 += 1; return $0 }) == 1 { throw URLError(.timedOut) }
                settings.update { $0 = updated }
                return .completed(updated, key: key.value, command: .changeWorkspaceSettings)
            }
        }
        let model = WorkspaceSettingsModel(api: owner)
        await model.load()
        let draft: [Field: String] = [
            .leaseLength: "900", .checkQueueTimeout: "180", .checkRunTimeout: "200",
            .maximumRounds: "5", .rerunLimit: "4", .recoveryTimeCeiling: "8000",
        ]
        model.fields = draft
        await model.save()
        #expect(model.state == .failed(.cannotReach))
        #expect(model.fields == draft)
        #expect(model.canSave)
        await model.save()
        let changes = owner.calls.filter { $0.operation == .changeWorkspaceSettings }
        try #require(changes.count == 2)
        #expect(changes[0].key != nil)
        #expect(changes[0].key == changes[1].key)
        let body: JSONValue = .object([
            "lease_length_seconds": .number(900),
            "check_queue_timeout_seconds": .number(180),
            "check_run_timeout_seconds": .number(200),
            "maximum_rounds": .number(5),
            "rerun_limit": .number(4),
            "recovery_time_ceiling_seconds": .number(8000),
        ])
        #expect(changes.map(\.body) == [body, body])
        #expect(model.fields == draft)
        #expect(model.state == .loaded)
        #expect(!model.canSave)
    }

    @Test("A settings event refreshes clean fields while the owner's draft stays in place")
    func eventRefresh() async throws {
        let owner = makeOwner()
        let updated = WorkspaceSettings(
            leaseLengthSeconds: 600, checkQueueTimeoutSeconds: 120, checkRunTimeoutSeconds: 120,
            maximumRounds: 3, rerunLimit: 3, recoveryTimeCeilingSeconds: 3600)
        let event = EventRecord(
            id: UUID(), workspaceID: UUID(), seq: 1, at: Date(), type: .workspaceSettingsChanged, actorKind: .owner)
        owner.script {
            $0.events = { after, _, _ in
                if after == 0 { return EventsPage(events: [event], nextAfterSeq: 1) }
                throw CancellationError()
            }
        }
        let model = WorkspaceSettingsModel(api: owner)
        let feed = EventFeed(owner: owner)
        defer {
            model.detach()
            feed.stop()
        }
        model.attach(to: feed)
        await model.load()
        model.fields[.leaseLength] = "900"
        owner.script { $0.workspaceSettings = { updated } }
        feed.noteRead(asOfSeq: 0)
        let deadline = ContinuousClock.now.advanced(by: Patience.scaled(.seconds(1)))
        while model.fields[.checkQueueTimeout] != "120", .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.fields[.checkQueueTimeout] == "120")
        #expect(model.fields[.leaseLength] == "900")
        #expect(model.canSave)
        #expect(owner.calls.filter { $0.operation == .getWorkspaceSettings }.count == 2)
    }
}
