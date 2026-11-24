import Foundation
import LeverageKit

enum CodexUsageParser {
    static func parse(rateLimits: Data, usage: Data) -> UsageReading {
        let decoder = JSONDecoder()
        guard let rateReply = try? decoder.decode([String: JSONValue].self, from: rateLimits),
              let snapshots = rateReply["rateLimits"]?.objectValue,
              let usageReply = try? decoder.decode([String: JSONValue].self, from: usage),
              let summary = usageReply["summary"]?.objectValue
        else { return UsageReading(state: .unavailable) }

        let windows = [snapshots["primary"], snapshots["secondary"]]
        let limits = windows.compactMap(limit)
        let activity = [
            activity("Lifetime tokens", count: summary["lifetimeTokens"]),
            activity("Peak daily tokens", count: summary["peakDailyTokens"]),
        ].compactMap { $0 }
        return UsageReading(state: .ok, figures: limits + activity, resets: resets(rateReply["rateLimitResetCredits"]))
    }

    private static func limit(_ snapshot: JSONValue?) -> Figure? {
        guard let snapshot, let percent = snapshot["usedPercent"]?.numberValue, (0...100).contains(percent)
        else { return nil }

        let window: LimitWindow
        let label: String
        switch snapshot["windowDurationMins"]?.intValue {
        case 300: (window, label) = (.fiveHour, "5-hour window")
        case 10_080: (window, label) = (.weekly, "Weekly window")
        default: return nil
        }
        let value = snapshot["resetsAt"]
        let resetAt = date(value)
        guard value == nil || value == .null || resetAt != nil else { return nil }
        return Figure(
            label: label, kind: .limit, window: window, percentUsed: (percent * 10).rounded() / 10,
            resetAt: resetAt, value: nil)
    }

    private static func activity(_ label: String, count: JSONValue?) -> Figure? {
        guard let count = count?.intValue, count >= 0, let number = Double(exactly: count) else { return nil }
        return Figure(label: label, kind: .activity, window: nil, percentUsed: nil, resetAt: nil, value: .number(number))
    }

    private static func resets(_ source: JSONValue?) -> [Reset]? {
        guard let source, let count = source["availableCount"]?.intValue, count >= 0 else { return nil }
        if count == 0 { return [] }
        let listed = source["credits"]
        let credits = listed?.arrayValue ?? []
        guard listed == nil || listed == .null || listed?.arrayValue != nil else { return nil }
        var countsByExpiry: [Date?: Int] = [:]
        var listedCount = 0
        for credit in credits {
            guard let status = credit["status"]?.stringValue, let type = credit["resetType"]?.stringValue
            else { return nil }
            guard status == "available", type == "codexRateLimits" else { continue }
            let expiry = credit["expiresAt"]
            let expiresAt = date(expiry)
            guard expiry == nil || expiry == .null || expiresAt != nil else { return nil }
            countsByExpiry[expiresAt, default: 0] += 1
            listedCount += 1
        }
        guard listedCount <= count else { return nil }
        if count > credits.count {
            countsByExpiry[nil, default: 0] += count - credits.count
        }
        // Sending a truncated list would misstate the number of resets.
        guard countsByExpiry.count <= 16 else { return nil }
        return countsByExpiry.sorted { lhs, rhs in
            guard let expiry = lhs.key else { return false }
            return rhs.key.map { expiry < $0 } ?? true
        }.map { Reset(count: $0.value, kind: .full, expiresAt: $0.key) }
    }

    private static func date(_ value: JSONValue?) -> Date? {
        // The app-server supplies integer seconds. Only years representable
        // by the contract's four-digit RFC 3339 dates can be reported.
        guard let seconds = value?.intValue, (-62_135_596_800...253_402_300_799).contains(seconds)
        else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }
}
