import Foundation
import LeverageKit

struct TokenChecks: Sendable {
    let pending: PendingTokens
    let vault: any TokenVault
    let http: ProviderHTTP
    let timeout: Duration

    func run(_ provider: Provider, credentialID: UUID, adding: Bool, check: inout CheckRun) async -> HelperRequestResult {
        await check.report(HelperCheckProgress(check: .tokenWorks, state: .waiting))
        await check.report(HelperCheckProgress(check: .tokenWorks, state: .running))

        do {
            let token: String?
            if adding {
                token = await pending.take(credentialID: credentialID)
            } else {
                token = try vault.read(credentialID: credentialID)
            }
            try Task.checkCancellation()
            guard let token else {
                return await check.fail(.tokenWorks, adding ? .timedOut : .notSignedIn)
            }
            guard !token.isEmpty else { return await check.fail(.tokenWorks, .rejected) }

            let reply = try await http.get(provider, token: token, timeout: timeout)
            if let failure = Self.failure(of: reply, provider: provider) {
                return await check.fail(.tokenWorks, failure)
            }
            try Task.checkCancellation()
            if adding { try vault.store(token, credentialID: credentialID) }
            await check.pass(.tokenWorks)
            return check.result(.finished)
        } catch let failure as ProviderHTTP.Failure where failure.code == .timedOut {
            return await check.fail(.tokenWorks, .timedOut)
        } catch {
            return await check.fail(.tokenWorks, .unreachable)
        }
    }

    private static func failure(of reply: ProviderHTTP.Response, provider: Provider) -> HelperCheckFailure? {
        switch reply.status {
        case 401, 403: return .rejected
        case 200:
            guard provider == .grokApi else { return nil }
            guard let blocked = TokenReaders.grokBlocked(in: reply.body) else { return .unreachable }
            return blocked ? .rejected : nil
        default: return .unreachable
        }
    }
}
