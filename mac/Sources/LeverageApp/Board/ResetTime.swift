import Foundation

/// The time and the calendar the words of a card are written against, so a
/// test can fix them.
struct ResetClock: Sendable {
    var now: @Sendable () -> Date
    var calendar: Calendar
    var locale: Locale

    static let system = ResetClock(now: { Date() }, calendar: .current, locale: .current)
}

/// A reset time as the Mac's short time, with the weekday when it is not today (HM-42).
enum ResetTime {
    static func text(for date: Date, clock: ResetClock) -> String {
        ""
    }
}
