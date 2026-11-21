import Foundation
import LeverageKit

struct AccountFacts: Sendable {
    struct Result: Sendable {
        var plan: String?
        var email: String?
    }

    typealias Read = @Sendable (ReaderAccount) async -> Result

    var read: Read

    init(read: @escaping Read) { self.read = read }

    init(testedCodexVersions: [String] = Provider.codex.testedToolVersions) {
        read = { _ in Result() }
    }

    static func claudeStatus(_ data: Data) -> Result { Result() }
}
