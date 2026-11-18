import Foundation

/// Amounts in milliunits (SPEC 3.7): 1000 milliunits is one unit of the
/// plan's currency.
enum Money {
    /// SPEC 3.7's limit on an amount in a request.
    static let limit = 1_000_000_000_000

    static func decimal(_ milliunits: Int) -> Decimal {
        Decimal(milliunits) / 1000
    }

    static func format(_ milliunits: Int, currencyCode: String, locale: Locale = .current) -> String {
        decimal(milliunits).formatted(.currency(code: currencyCode).locale(locale))
    }

    /// Reads an amount the user typed, with or without the currency symbol
    /// and grouping separators. Empty text is 0. Returns `nil` for anything
    /// that isn't a number, has more than three decimal places, or is beyond
    /// SPEC 3.7's limit.
    static func parse(_ text: String, currencyCode: String, locale: Locale = .current) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }

        let currency = Decimal.FormatStyle.Currency(code: currencyCode, locale: locale)
        let number = Decimal.FormatStyle(locale: locale)
        guard let value = (try? currency.parseStrategy.parse(text))
            ?? (try? number.parseStrategy.parse(text))
        else { return nil }

        var milliunits = value * 1000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &milliunits, 0, .plain)
        guard rounded == milliunits, abs(rounded) <= Decimal(limit) else { return nil }
        return Int(truncating: NSDecimalNumber(decimal: rounded))
    }
}
