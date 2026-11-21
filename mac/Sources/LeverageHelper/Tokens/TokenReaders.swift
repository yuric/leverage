import Foundation
import LeverageKit

enum TokenReaders {
    static func responseHeaders(for provider: Provider) -> [String] {
        []
    }

    static func read(provider: Provider, status: Int, headers: [String: String], body: Data) -> UsageReading {
        UsageReading(state: .unavailable)
    }

    static func grokBlocked(in body: Data) -> Bool? {
        nil
    }
}
