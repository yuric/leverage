import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

@Suite("Copy catalogs")
struct CopyCatalogListTests {
    @Test("the registered copy catalogs are listed in order and have text")
    func everyCatalogListed() {
        let names = CopyCatalogs.all.map { String(describing: $0) }
        #expect(names == [
            "ShellCopy", "SignInCopy", "BoardCopy", "AddTaskCopy", "TaskPageCopy", "AgentsCopy",
            "CredentialsCopy", "AddTokenCopy", "NeedsYouCopy", "HandoffCopy", "RulesCopy", "DecidedCopy",
            "ActivityCopy", "ProjectsCopy", "WorkspaceSettingsCopy", "SetupAssistantCopy", "SetupChecklistCopy",
        ])
        for catalog in CopyCatalogs.all {
            #expect(!catalog.allTexts.isEmpty)
            #expect(catalog.allTexts.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("where the services are not built, the app runs with nothing started")
    func liveRuntime() async {
        #expect(await Live.runtime().server.state() == .notStarted)
    }
}
