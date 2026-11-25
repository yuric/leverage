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
            "CredentialsCopy", "AddTokenCopy", "NeedsYouCopy", "HandoffCopy", "ImaginariumCopy", "RulesCopy", "DecidedCopy",
            "ActivityCopy", "ProjectsCopy", "WorkspaceSettingsCopy", "SetupAssistantCopy", "SetupChecklistCopy",
        ])
        for catalog in CopyCatalogs.all {
            #expect(!catalog.allTexts.isEmpty)
            #expect(catalog.allTexts.allSatisfy { !$0.isEmpty })
        }
    }

    // Only where the services are not built: with them, Live.runtime()
    // opens the real support folder, and when the owner's Leverage is
    // running there it quits the whole test process (exit 0), ending the
    // run early with a false pass.
    @Test("where the services are not built, the app runs with nothing started",
          .enabled(if: !Live.servicesAreBuilt))
    func liveRuntime() async {
        #expect(await Live.runtime().server.state() == .notStarted)
    }
}
