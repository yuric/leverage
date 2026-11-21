import Foundation
import LeverageKit

struct LocalChannel: Sendable {
    let cleanup: CredentialCleanup
    let log: Log

    func run(input: FileHandle) async {}
}
