import Foundation
import LeverageKit
import Testing
@testable import LeverageMCP

struct ToolCatalogTests {
    @Test func catalogMatchesGeneratedAgentToolsAndAddsControlArguments() throws {
        let catalog = ToolCatalog()
        #expect(catalog.tools.count == 24)
        #expect(catalog.tools.map(\.name) == AgentTools.all.map(\.id))
        #expect(Set(catalog.tools.map(\.name)).count == 24)
        for tool in catalog.tools {
            #expect(tool.name.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil)
            #expect(tool.inputSchema["type"] == .string("object"))
            let properties = try #require(tool.inputSchema["properties"]?.objectValue)
            #expect((properties["idempotency_key"] != nil) == (tool.operation.method == .post))
            #expect(tool.inputSchema["required"]?.arrayValue?.contains(.string("idempotency_key")) == false)
            #expect((properties["wait"] != nil) == (tool.operation == .getNext))
        }
        let next = try #require(catalog.tool(named: "get_next"))
        let wait = next.inputSchema["properties"]?["wait"]
        #expect(wait?["minimum"] == .number(0))
        #expect(wait?["maximum"] == .number(30))
        #expect(wait?["default"] == .number(20))
        let start = try #require(catalog.tool(named: "start_action"))
        #expect(start.description.contains("before carrying out"))
    }

    @Test(arguments: SeatRole.allCases)
    func roleLimitsListingAndLookup(role: SeatRole) {
        let catalog = ToolCatalog(role: role)
        let names = AgentTools.all.filter { $0.roles.contains(role) }.map(\.id)
        #expect(catalog.tools.map(\.name) == names)
        if role == .builder { #expect(names.count == 16) }
        for tool in AgentTools.all {
            #expect((catalog.tool(named: tool.id) != nil) == names.contains(tool.id))
        }
    }
}
