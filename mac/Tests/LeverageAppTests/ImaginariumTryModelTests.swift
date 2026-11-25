import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@MainActor
@Suite("Imaginarium Try it")
struct ImaginariumTryModelTests {
    private let project = UUID()

    private func makeModel(_ owner: FakeOwnerAPI = FakeOwnerAPI()) -> ImaginariumTryModel {
        let entry = ImaginariumCatalog.Entry(
            id: "pocket-to-do", category: "apps", title: "Pocket to-do", description: "A calm to-do app.",
            minutes: 40, fills: [.init(key: "look", label: "Look", defaultValue: "paper")],
            prompt: "Build a to-do app styled like {look}.", doneWhen: ["It opens", "Tasks are kept"], needs: [])
        return ImaginariumTryModel(entry: entry, catalogVersion: 7, api: owner)
    }

    private func owner() -> FakeOwnerAPI {
        let api = FakeOwnerAPI()
        let id = UUID()
        api.script {
            $0.addTask = { _, key in .completed(TaskCreatedResult(taskID: id), key: key.value, command: .addTask) }
            $0.completeContract = { _, _, key in .completed(nil, key: key.value, command: .completeContract) }
        }
        return api
    }

    @Test func editingKeepsTheOwnersTextUntilTheyUndoIt() {
        let model = makeModel()
        #expect(model.prompt == "Build a to-do app styled like paper.")
        model.fills["look"] = "glass"
        #expect(model.prompt == "Build a to-do app styled like glass.")
        model.prompt = "My edited prompt."
        model.fills["look"] = "wood"
        #expect(model.prompt == "My edited prompt.")
        #expect(model.isEdited)
        model.undoEdits()
        #expect(model.prompt == "Build a to-do app styled like wood.")
        #expect(!model.isEdited)
    }

    @Test func ideasSavesThePromptAndCriteriaOnce() async throws {
        let api = owner()
        let model = makeModel(api)
        model.prompt = "Make a checklist.\n"
        await model.submit(.ideas, projectID: project)
        await model.submit(.ideas, projectID: project)
        let added = try api.call(at: 0)
        #expect(api.calls.map(\.operation) == [.addTask])
        #expect(added.body?["state"] == .string("ideas"))
        #expect(added.body?["details"] == .string("Make a checklist.\n"))
        #expect(added.body?["criteria"] == FakeCall.json(model.criteria))
        #expect(added.body?["imaginarium"]?["entry_id"] == .string("pocket-to-do"))
        #expect(added.body?["imaginarium"]?["catalog_version"] == FakeCall.json(7))
        #expect(model.criteria.last?.kind == .review)
        #expect(model.state == .saved(.ideas, reason: nil))
        #expect(model.savedProjectID == project)
    }

    @Test func readyCompletesTheStoredTaskAndKeepsItsKeysOnRetry() async throws {
        let api = owner()
        api.script { $0.completeContract = { _, _, _ in throw URLError(.timedOut) } }
        let model = makeModel(api)
        await model.submit(.ready, projectID: project)
        let first = try api.call(at: 1)
        api.script { $0.completeContract = { _, _, key in .completed(nil, key: key.value, command: .completeContract) } }
        await model.retry()
        #expect(api.calls.map(\.operation) == [.addTask, .completeContract, .completeContract])
        #expect(first == (try api.call(at: 2)))
        #expect(first.body?["criteria"] == FakeCall.json(model.criteria))
        #expect((try api.call(at: 0)).body?["criteria"] == nil)
        #expect(model.state == .saved(.ready, reason: nil))
    }

    @Test func pendingRuleRefusalShowsTheTaskInBacklogWithItsReason() async {
        let api = owner()
        api.script {
            $0.completeContract = { _, _, key in .pending(key: key.value, command: .completeContract) }
            $0.command = { key in
                .refused(.init(code: .blockedByRule, ruleID: UUID(), reason: "Name the intended audience."),
                         key: key.value, command: .completeContract)
            }
        }
        let model = makeModel(api)
        await model.submit(.ready, projectID: project)
        #expect(model.state == .checking)
        await model.checkStatus()
        #expect(model.state == .saved(.backlog, reason: "Name the intended audience."))
    }

    @Test func rejectedAddLetsTheOwnerChangeThePrompt() async throws {
        let api = owner()
        api.script { $0.addTask = { _, _ in throw TransportError(code: .invalid, message: "Check these details.") } }
        let model = makeModel(api)
        await model.submit(.ideas, projectID: project)
        #expect(model.canEdit)
        let id = UUID()
        api.script { $0.addTask = { _, key in .completed(TaskCreatedResult(taskID: id), key: key.value, command: .addTask) } }
        model.prompt = "Simplify the prompt."
        await model.submit(.ideas, projectID: project)
        #expect((try api.call(at: 1)).body?["details"] == .string("Simplify the prompt."))
        #expect((try api.call(at: 0)).key != (try api.call(at: 1)).key)
        #expect(model.state == .saved(.ideas, reason: nil))
    }
}
