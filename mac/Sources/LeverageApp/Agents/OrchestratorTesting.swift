import Foundation
import LeverageKit

/// Whether an orchestrator is one the eval suite did not cover (RV-5). The
/// suite ran each tool's default model on its own login, so a provider that
/// is not in `orchestrator_tested_providers`, a model the owner chose, and an
/// agent that connects on its own are not covered. The answer only changes
/// what the screen says: nothing is refused or disabled by it.
enum OrchestratorTesting {
    static func isUntested(provider: Provider?, model: String?, connectsOnItsOwn: Bool, tested: [Provider]) -> Bool {
        if connectsOnItsOwn { return true }
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let provider else { return false }
        return !tested.contains(provider)
    }
}
