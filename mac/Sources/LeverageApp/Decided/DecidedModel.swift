import Foundation
import LeverageKit
import Observation

@MainActor
@Observable
final class DecidedModel {
    let rows: [Decision] = []
    let confirming: Decision? = nil
    var answer = ""

    init(api: any OwnerAPI) {}
    func load() async {}
    func requestUndo(_ decision: Decision) {}
    func dismissUndo() {}
    func confirmUndo() async {}
    func mark(for decision: Decision) -> String { "" }
    func effect(for decision: Decision) -> String? { nil }
}
