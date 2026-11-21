import Foundation
import LeverageKit

/// Ends local work on an id that was removed and deletes the secrets
/// managed by the helper. A forgotten id stays forgotten until shutdown.
struct CredentialCleanup: Sendable {
    let folders: AccountFolders
    let pending: PendingTokens
    let vault: any TokenVault
    let requests: RunningRequests
    let log: Log

    func acceptToken(_ token: ProviderToken, credentialID: UUID) async {
        guard !requests.isForgotten(credentialID) else { return }
        await pending.insert(token, credentialID: credentialID)
        if requests.isForgotten(credentialID) {
            await pending.discard(credentialID: credentialID)
        }
    }

    func forget(_ credentialID: UUID) async {
        let work = requests.forget(credentialID)
        for task in work { task.cancel() }
        await pending.discard(credentialID: credentialID)
        // A cancelled Add may still have been inside a file or vault
        // operation. Wait for it to end before deleting anything.
        for task in work { await task.value }
        var deletedToken = false
        do {
            try vault.delete(credentialID: credentialID)
            deletedToken = true
        } catch {
            log.warning("could not delete the saved token of credential \(credentialID.contractString)")
        }
        do {
            let removals = PendingCredentialRemovals(supportFolder: folders.root.deletingLastPathComponent())
            let confirmed = try removals.contains(credentialID)
            try AccountFolderRemoval.remove(credentialID, from: folders, confirmed: confirmed)
            if confirmed && deletedToken { try removals.complete(credentialID) }
        } catch {
            log.warning("could not complete cleanup of credential \(credentialID.contractString)")
        }
    }

    /// Record ownership at creation. The identity also rules out a copied
    /// account folder containing another folder's marker.
    func createFolder(for credentialID: UUID) throws -> URL {
        let folder = try folders.createFresh(for: credentialID)
        do {
            try identity(of: folder).write(to: marker(in: folder), options: .atomic)
            return folder
        } catch {
            folders.remove(for: credentialID)
            throw error
        }
    }

    private func marker(in folder: URL) -> URL {
        folder.appendingPathComponent(".leverage-owned")
    }

    private func identity(of folder: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return Data("\(device):\(inode)\n".utf8)
    }
}
