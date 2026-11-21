import Foundation
import LeverageKit

struct UsageRead: Sendable {
    let api: any HelperAPI
    let settings: HelperSettings
    let timings: HelperTimings
    let http: ProviderHTTP
    let vault: any TokenVault
    let log: Log
    var readers: UsageReaders.Lookup = UsageReaders.reader(for:)
    var testedVersions: @Sendable (Provider) -> [String] = { $0.testedToolVersions }
    var now: @Sendable () -> Date = { Date() }

    func run(_ request: HelperRequest) async -> HelperRequestResult {
        HelperRequestResult(outcome: .failed, checks: [], toolVersion: nil)
    }
}
