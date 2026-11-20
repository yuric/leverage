import Foundation

/// The Mac side's logging mechanism (plan CL-29): one line per message on
/// standard error, after `Redaction`. The app sends the helper's standard
/// error to a file, and the helper each run's; nothing else writes logs.
///
///     2026-11-19T10:00:00Z helper info: started the run of seat 0b4e…
public struct Log: Sendable {
    public enum Level: String, Sendable {
        case info, warning, error
    }

    public let component: String
    private let write: @Sendable (String) -> Void
    private let now: @Sendable () -> Date

    /// `write` receives each finished line, newline included; the default
    /// writes it to standard error. `now` is the clock.
    public init(
        component: String,
        write: @escaping @Sendable (String) -> Void = Log.standardError,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.component = component
        self.write = write
        self.now = now
    }

    public func info(_ message: String) { log(.info, message) }
    public func warning(_ message: String) { log(.warning, message) }
    public func error(_ message: String) { log(.error, message) }

    public func log(_ level: Level, _ message: String) {
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        write("\(Log.timestamp(now())) \(component) \(level.rawValue): \(Redaction.redact(flat))\n")
    }

    public static let standardError: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// UTC, to the second, in the ISO 8601 form.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { value.map { $0 < 10 ? "0\($0)" : "\($0)" } ?? "00" }
        return "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))T"
            + "\(two(parts.hour)):\(two(parts.minute)):\(two(parts.second))Z"
    }
}
