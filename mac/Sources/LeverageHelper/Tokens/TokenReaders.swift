import Foundation
import LeverageKit

enum TokenReaders {
    static func responseHeaders(for provider: Provider) -> [String] {
        ProviderCatalog.tokenEntry(for: provider)?.responseHeaders.value ?? []
    }

    static func read(provider: Provider, status: Int, headers: [String: String], body: Data) -> UsageReading {
        guard provider.kind == .apiToken else { return UsageReading(state: .unavailable) }
        if status == 401 || status == 403 { return UsageReading(state: .signedOut) }
        guard status == 200, let reply = object(in: body) else { return UsageReading(state: .unavailable) }

        switch provider {
        case .openrouter:
            guard let key = reply["data"]?.objectValue else { return UsageReading(state: .unavailable) }
            return UsageReading(state: .ok, figures: openRouterFigures(key))
        case .claudeApi, .openaiApi:
            guard reply["data"]?.arrayValue != nil,
                  provider != .openaiApi || reply["object"]?.stringValue == "list"
            else { return UsageReading(state: .unavailable) }
            let figure = requestsRemaining(for: provider, headers: headers)
            return UsageReading(state: .ok, figures: figure.map { [$0] } ?? [])
        case .geminiApi:
            return UsageReading(state: reply["models"]?.arrayValue != nil ? .ok : .unavailable)
        case .grokApi:
            // The block flags affect the token check. The reading reports
            // the response status and carries no figures.
            return UsageReading(state: grokBlocked(in: reply) != nil ? .ok : .unavailable)
        case .claude, .codex, .gemini, .grok:
            return UsageReading(state: .unavailable)
        }
    }

    static func grokBlocked(in body: Data) -> Bool? {
        guard let reply = object(in: body) else { return nil }
        return grokBlocked(in: reply)
    }

    private static func grokBlocked(in reply: [String: JSONValue]) -> Bool? {
        let flags = ["api_key_blocked", "api_key_disabled", "team_blocked"].compactMap { reply[$0] }
        if flags.contains(.bool(true)) { return true }
        return flags.allSatisfy { $0 == .bool(false) } ? false : nil
    }

    private static func object(in body: Data) -> [String: JSONValue]? {
        (try? JSONDecoder().decode(JSONValue.self, from: body))?.objectValue
    }

    private static func requestsRemaining(for provider: Provider, headers: [String: String]) -> Figure? {
        guard let header = responseHeaders(for: provider).first,
              let text = headers[header]?.trimmingCharacters(in: .whitespaces),
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(text), let value = Double(exactly: count),
              let label = provider.figureLabels.first
        else { return nil }
        return Figure(label: label, kind: .allowance, window: nil, percentUsed: nil, resetAt: nil, value: .number(value))
    }

    private static func openRouterFigures(_ key: [String: JSONValue]) -> [Figure] {
        var figures: [Figure] = []
        if let spendingLimit = spendingLimit(key) { figures.append(spendingLimit) }
        let amounts: [(field: String, label: String, kind: FigureKind)] = [
            ("limit_remaining", "Left, in US dollars", .allowance),
            ("usage_daily", "Use today, in US dollars", .activity),
            ("usage_weekly", "Use this week, in US dollars", .activity),
            ("usage_monthly", "Use this month, in US dollars", .activity),
        ]
        for amount in amounts {
            guard let number = key[amount.field]?.numberValue, number.isFinite else { continue }
            figures.append(Figure(
                label: amount.label, kind: amount.kind, window: nil, percentUsed: nil, resetAt: nil, value: .number(number)))
        }
        return figures
    }

    private static func spendingLimit(_ key: [String: JSONValue]) -> Figure? {
        guard let limit = key["limit"]?.numberValue, limit.isFinite, limit > 0,
              let left = key["limit_remaining"]?.numberValue, (0...limit).contains(left)
        else { return nil }

        var resetAt: Date?
        if let reset = key["limit_reset"], reset != .null {
            guard let text = reset.stringValue, let date = LeverageJSON.date(from: text) else { return nil }
            resetAt = date
        }

        let percent = (((limit - left) / limit) * 1_000).rounded() / 10
        return Figure(
            label: "Spending limit", kind: .limit, window: .spend, percentUsed: percent, resetAt: resetAt, value: nil)
    }
}
