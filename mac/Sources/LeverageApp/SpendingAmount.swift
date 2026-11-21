import Foundation

enum SpendingAmount {
    private static let posix = Locale(identifier: "en_US_POSIX")

    // Fields use the Mac's decimal separator and accept at most two
    // fractional digits. Grouping, signs and partial parses are invalid.
    static func parse(_ text: String, locale: Locale) -> Decimal? {
        let parts = text.components(separatedBy: locale.decimalSeparator ?? ".")
        guard let whole = parts.first, !whole.isEmpty, parts.count <= 2,
              parts.count == 1 || (1...2).contains(parts[1].count)
        else { return nil }

        var normalized: [String] = []
        for part in parts {
            var digits = ""
            for digit in part {
                guard digit.unicodeScalars.count == 1,
                      let scalar = digit.unicodeScalars.first, CharacterSet.decimalDigits.contains(scalar),
                      let value = digit.wholeNumberValue
                else { return nil }
                digits += String(value)
            }
            normalized.append(digits)
        }

        guard let amount = Decimal(string: normalized.joined(separator: "."), locale: posix),
              amount < 100_000_000
        else { return nil }
        return amount
    }

    static func fieldText(_ amount: Decimal?, locale: Locale) -> String {
        amount?.formatted(.number.grouping(.never).precision(.fractionLength(2)).locale(locale)) ?? ""
    }
}
