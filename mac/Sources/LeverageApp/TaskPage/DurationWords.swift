import Foundation

/// How long something took, in words: "45 seconds", "25 minutes", "1 hour 5 minutes".
/// Under a minute it counts seconds, under an hour whole minutes, and beyond
/// that hours and the minutes left over.
enum DurationWords {
    static func text(seconds: Int) -> String {
        let total = max(0, seconds)
        if total < 60 { return unit(total, "second") }
        if total < 3600 { return unit(total / 60, "minute") }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? unit(hours, "hour") : "\(unit(hours, "hour")) \(unit(minutes, "minute"))"
    }

    private static func unit(_ count: Int, _ name: String) -> String {
        "\(count) \(name)\(count == 1 ? "" : "s")"
    }
}
