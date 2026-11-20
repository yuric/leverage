import Foundation

/// The time and the calendar the words of a card are written against, so a
/// test can fix them.
struct ResetClock: Sendable {
    var now: @Sendable () -> Date
    var calendar: Calendar
    var locale: Locale

    static let system = ResetClock(now: { Date() }, calendar: .current, locale: .current)
}

/// A reset time as the Mac's short time, with the weekday when it is not today
/// (HM-42). A day more than six days away, or one already past, gets its date
/// instead, because a weekday name would be taken for the next one.
enum ResetTime {
    static func text(for date: Date, clock: ResetClock) -> String {
        let calendar = clock.calendar
        let now = clock.now()
        func format(_ style: Date.FormatStyle) -> String { date.formatted(style) }
        func base() -> Date.FormatStyle {
            Date.FormatStyle(locale: clock.locale, calendar: calendar, timeZone: calendar.timeZone)
        }
        let time = format(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: clock.locale, calendar: calendar,
                timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if (1...6).contains(days) {
            return "\(format(base().weekday(.wide))) \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? format(base().month(.abbreviated).day()) : format(base().month(.abbreviated).day().year())
        return "\(day), \(time)"
    }
}
