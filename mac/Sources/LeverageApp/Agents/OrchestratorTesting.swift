import Foundation
import LeverageKit

/// Whether a General or Orchestrator seat is outside its eval coverage
/// (GA-11, RV-5). Each role has its own tested provider list. Coverage uses
/// the tool's default model and a login the app runs.
enum OrchestratorTesting {
    static func isUntested(provider: Provider?, model: String?, connectsOnItsOwn: Bool, tested: [Provider]) -> Bool {
        if connectsOnItsOwn { return true }
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let provider else { return false }
        return !tested.contains(provider)
    }
}
