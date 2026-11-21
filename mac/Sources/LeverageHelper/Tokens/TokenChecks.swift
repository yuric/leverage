import Foundation
import LeverageKit

struct TokenChecks: Sendable {
    let pending: PendingTokens
    let vault: any TokenVault
    let http: ProviderHTTP
    let timeout: Duration

    func run(_ provider: Provider, credentialID: UUID, adding: Bool, check: inout CheckRun) async -> HelperRequestResult {
        await check.fail(.tokenWorks, .unreachable)
    }
}
