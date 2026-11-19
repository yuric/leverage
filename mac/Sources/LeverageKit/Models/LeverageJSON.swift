import Foundation

/// How the Mac side reads and writes the contract's JSON: explicit coding
/// keys on every model (no key strategy, which would also rewrite the keys
/// of a payload), and dates as RFC 3339 `date-time` strings.
///
/// Dates are read with or without fractional seconds and with `Z` or an
/// offset, and written in UTC with up to six fractional digits, so that a
/// time the server gave (as `updated_at`) goes back to it unchanged. The
/// arithmetic is done here rather than with a date formatter, so it reads
/// the same on macOS and Linux.
public enum LeverageJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an RFC 3339 date-time: \(text)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    /// Reads `YYYY-MM-DDTHH:MM:SS[.fraction](Z|+HH:MM|-HH:MM)`.
    public static func date(from text: String) -> Date? {
        let characters = Array(text.utf8)
        var index = 0

        func number(_ width: Int) -> Int? {
            guard index + width <= characters.count else { return nil }
            var value = 0
            for character in characters[index..<(index + width)] {
                guard (48...57).contains(character) else { return nil }
                value = value * 10 + Int(character - 48)
            }
            index += width
            return value
        }
        func expect(_ allowed: String) -> Bool {
            guard index < characters.count, allowed.utf8.contains(characters[index]) else { return false }
            index += 1
            return true
        }

        guard let year = number(4), expect("-"), let month = number(2), expect("-"),
              let day = number(2), expect("Tt"), let hour = number(2), expect(":"),
              let minute = number(2), expect(":"), let second = number(2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var digits = ""
        if index < characters.count, characters[index] == UInt8(ascii: ".") {
            index += 1
            while index < characters.count, (48...57).contains(characters[index]) {
                digits.append(Character(UnicodeScalar(characters[index])))
                index += 1
            }
            if digits.isEmpty { return nil }
        }

        var offset = 0
        guard index < characters.count else { return nil }
        if expect("Zz") {
        } else if index < characters.count, characters[index] == UInt8(ascii: "+") || characters[index] == UInt8(ascii: "-") {
            let sign = characters[index] == UInt8(ascii: "-") ? -1 : 1
            index += 1
            guard let hours = number(2), expect(":"), let minutes = number(2), hours < 24, minutes < 60
            else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        } else {
            return nil
        }
        guard index == characters.count else { return nil }

        let whole = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second - offset
        if digits.isEmpty { return Date(timeIntervalSince1970: Double(whole)) }
        // Through the decimal text, so the value is the nearest Double to
        // what was written.
        if whole >= 0, let seconds = Double("\(whole).\(digits)") {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let fraction = Double("0.\(digits)") else { return nil }
        return Date(timeIntervalSince1970: Double(whole) + fraction)
    }

    /// Writes the date in UTC, with its microseconds when it has any.
    public static func string(from date: Date) -> String {
        var whole = Int(date.timeIntervalSince1970.rounded(.down))
        var micros = Int(((date.timeIntervalSince1970 - Double(whole)) * 1_000_000).rounded())
        if micros >= 1_000_000 {
            whole += 1
            micros -= 1_000_000
        }
        let days = Int((Double(whole) / 86_400).rounded(.down))
        let secondsOfDay = whole - days * 86_400
        let (year, month, day) = civilFromDays(days)
        var text = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2) + "T"
            + pad(secondsOfDay / 3600, 2) + ":" + pad(secondsOfDay / 60 % 60, 2) + ":" + pad(secondsOfDay % 60, 2)
        if micros > 0 {
            var fraction = pad(micros, 6)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return text + "Z"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // Howard Hinnant's days_from_civil and civil_from_days, in the proleptic
    // Gregorian calendar, counting from 1970-01-01.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

extension KeyedEncodingContainer {
    /// Writes an id in lower case, as the server writes it, and null for nil.
    mutating func encodeID(_ id: UUID?, forKey key: Key) throws {
        try encode(id.map { $0.uuidString.lowercased() }, forKey: key)
    }

    mutating func encodeIDs(_ ids: [UUID], forKey key: Key) throws {
        try encode(ids.map { $0.uuidString.lowercased() }, forKey: key)
    }
}

extension UUID {
    /// The id as the server writes it, in lower case.
    public var contractString: String { uuidString.lowercased() }
}
