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
    /// Which add last began for each credential.
    var adds = LatestAdds()

    /// Notes that an add of the request's credential begins, before it
    /// saves anything.
    func addBegan(_ request: HelperRequest) {
        guard let credentialID = request.credentialID else { return }
        adds.began(request.id, credentialID: credentialID)
    }

    /// Undoes what a finished add saved on this Mac, the token and the
    /// account folder, when the server did not take the add's result. The
    /// server deletes the unverified row at the next helper start and the
    /// id is never listed again, so nothing else would ever remove them.
    ///
    /// It does nothing once a later add of the same credential began (the
    /// Add sheet's Retry uses the same id, IN-24): what is saved then is
    /// that add's. Unlike `forget`, the id is not forgotten, so Retry
    /// works. True when it removed what the add saved.
    @discardableResult
    func rollBackAdd(_ request: HelperRequest) -> Bool {
        guard let credentialID = request.credentialID else { return false }
        let undone = adds.ifStillLatest(request.id, credentialID: credentialID) {
            do {
                try vault.delete(credentialID: credentialID)
            } catch {
                log.warning("could not delete the saved token of credential \(credentialID.contractString)")
            }
            // The folder this add made, as a failed add removes it.
            folders.remove(for: credentialID)
        }
        if undone {
            log.info("removed what the add of credential \(credentialID.contractString) saved: its result was not taken")
        }
        return undone
    }

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
            do {
                try AccountFolderRemoval.remove(credentialID, from: folders, confirmed: confirmed)
            } catch AccountFolderRemoval.Refusal.ownershipUnproven {
                log.warning("kept the settings folder of credential \(credentialID.contractString) because ownership could not be verified")
            }
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

/// Which add request last began for each credential, so that an earlier
/// add's late rollback never removes what a later add of the same id saved.
/// A later add that begins while a rollback runs waits for it, and then
/// makes its folder and saves its token afresh.
final class LatestAdds: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [UUID: UUID] = [:]

    func began(_ requestID: UUID, credentialID: UUID) {
        lock.withLock { latest[credentialID] = requestID }
    }

    /// Runs `undo` when `requestID` is still the credential's latest add;
    /// true when it ran.
    func ifStillLatest(_ requestID: UUID, credentialID: UUID, _ undo: () -> Void) -> Bool {
        lock.withLock {
            guard latest[credentialID] == requestID else { return false }
            undo()
            return true
        }
    }
}
