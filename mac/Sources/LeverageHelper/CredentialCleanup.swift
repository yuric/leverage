import Foundation
import LeverageKit

struct CredentialCleanup: Sendable {
    let folders: AccountFolders
    let pending: PendingTokens
    let vault: any TokenVault
    let requests: RunningRequests
    let log: Log

    func forget(_ credentialID: UUID) async {}

    func createFolder(for credentialID: UUID) throws -> URL {
        try folders.createFresh(for: credentialID)
    }
}
