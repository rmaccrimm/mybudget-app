import Foundation

/// Amounts in milliunits (SPEC 3.7): 1000 milliunits is one unit of the
/// plan's currency.
enum Money {
    /// SPEC 3.7's limit on an amount in a request.
    static let limit = 1_000_000_000_000

    static func decimal(_ milliunits: Int) -> Decimal {
        Decimal(milliunits) / 1000
    }

    /// The amount with its currency symbol. `narrow` writes the bare symbol
    /// ("$0.00") where the standard one would name the country ("US$0.00").
    static func format(
        _ milliunits: Int, currencyCode: String, locale: Locale = .current, narrow: Bool = false
    ) -> String {
        var style = Decimal.FormatStyle.Currency(code: currencyCode, locale: locale)
        if narrow { style = style.presentation(.narrow) }
        return decimal(milliunits).formatted(style)
    }

    /// The narrow currency symbol, such as "$", and whether it comes before
    /// the number in `locale`.
    static func symbol(currencyCode: String, locale: Locale = .current) -> (text: String, leads: Bool) {
        let zero = format(0, currencyCode: currencyCode, locale: locale, narrow: true)
        let numeric = CharacterSet.decimalDigits
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "\u{00A0}\u{202F}"))
            .union(CharacterSet(charactersIn: (locale.decimalSeparator ?? ".") + (locale.groupingSeparator ?? ",")))
        let text = String(String.UnicodeScalarView(zero.unicodeScalars.filter { !numeric.contains($0) }))
        let leads = zero.first.map { !$0.isNumber } ?? true
        return (text, leads)
    }

    /// The amount as `format` writes it with the narrow symbol, less the
    /// symbol: "-350.00" for -350000 in US dollars.
    static func formatNumber(_ milliunits: Int, currencyCode: String, locale: Locale = .current) -> String {
        let formatted = format(milliunits, currencyCode: currencyCode, locale: locale, narrow: true)
        let symbol = symbol(currencyCode: currencyCode, locale: locale).text
        guard !symbol.isEmpty else { return formatted }
        return formatted.replacingOccurrences(of: symbol, with: "")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{00A0}\u{202F}")))
    }

    /// Reads an amount the user typed, with or without the currency symbol
    /// (standard or narrow) and grouping separators. Empty text is 0. Returns
    /// `nil` for anything that isn't a number, has more than three decimal
    /// places, or is beyond SPEC 3.7's limit.
    static func parse(_ text: String, currencyCode: String, locale: Locale = .current) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }

        let currency = Decimal.FormatStyle.Currency(code: currencyCode, locale: locale)
        let number = Decimal.FormatStyle(locale: locale)
        let symbol = symbol(currencyCode: currencyCode, locale: locale).text
        let bare = symbol.isEmpty ? text : text.replacingOccurrences(of: symbol, with: "")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{00A0}\u{202F}")))
        guard let value = (try? currency.parseStrategy.parse(text))
            ?? (try? number.parseStrategy.parse(text))
            ?? (try? number.parseStrategy.parse(bare))
        else { return nil }

        var milliunits = value * 1000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &milliunits, 0, .plain)
        guard rounded == milliunits, abs(rounded) <= Decimal(limit) else { return nil }
        return Int(truncating: NSDecimalNumber(decimal: rounded))
    }
}
