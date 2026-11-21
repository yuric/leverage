import Foundation
import LeverageKit
import LeverageTestSupport
import Testing

@testable import LeverageApp

// Every screen folder has its catalog in the list from the first version;
// the Handoff milestone adds NeedsYou and Handoff, and the Rule checks
// milestone adds Rules (the Settings folder). WP16 owns the list from here.
@Suite("Copy catalogs")
struct CopyCatalogListTests {
    @Test("the list names one catalog per screen folder, each with a sentence")
    func everyCatalogListed() {
        let names = CopyCatalogs.all.map { String(describing: $0) }
        #expect(names == [
            "ShellCopy", "SignInCopy", "BoardCopy", "AddTaskCopy", "TaskPageCopy", "AgentsCopy",
            "CredentialsCopy", "NeedsYouCopy", "HandoffCopy", "RulesCopy",
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
