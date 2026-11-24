import Foundation
import Testing
@testable import LeverageKit

@Suite("Task text on the wire")
struct TaskTextTests {
    @Test("a task summary decodes title and details from the current contract")
    func taskSummary() throws {
        let example = try #require(ContractDocument.examples(of: "TaskSummary").first)
        let task = try LeverageJSON.decoder().decode(TaskSummary.self, from: ContractDocument.data(example))
        #expect(task.title == example["title"]?.stringValue)
        #expect(task.details == example["details"]?.stringValue)
    }

    @Test("a briefing contract reads and writes its title without a goal")
    func briefing() throws {
        let example = try #require(ContractDocument.examples(of: "Briefing").first)
        let briefing = try LeverageJSON.decoder().decode(Briefing.self, from: ContractDocument.data(example))
        let body = try json(briefing.contract)
        #expect(body["title"] == example["contract"]?["title"])
        #expect(body["details"] == example["contract"]?["details"])
        #expect(body["goal"] == nil)
    }

    @Test("Add task encodes a title-only request")
    func addTask() throws {
        let request = AddTaskRequest(title: "Refresh the price list", goal: "Old task text")
        #expect(try json(request) == .object(["title": .string(request.title)]))
    }

    @Test("Complete contract encodes details and omits the goal key")
    func completeContract() throws {
        let request = CompleteContractRequest(
            title: "Refresh the price list", goal: "Old task text", details: nil, criteria: [], workReference: nil)
        let body = try json(request)
        #expect(body["title"] == .string(request.title))
        #expect(body["details"] == .null)
        #expect(body["goal"] == nil)
    }

    @Test("a project carries its latest work reference and keeps its own goal")
    func project() throws {
        let example = try #require(ContractDocument.examples(of: "Project").first?.objectValue)
        let reference = JSONValue.string("/work/made-up-project")
        let withReference = example.merging(["latest_work_reference": reference]) { _, incoming in incoming }
        let project = try LeverageJSON.decoder().decode(Project.self, from: ContractDocument.data(.object(withReference)))
        #expect(try json(project)["latest_work_reference"] == reference)
        #expect(project.goal == example["goal"]?.stringValue)
    }

    private func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
