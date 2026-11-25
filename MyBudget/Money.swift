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
        let leads = zero.unicodeScalars.first { !isFormatMark($0) }
            .map { $0.properties.numericType != .decimal } ?? true
        return (symbolText(in: zero, locale: locale), leads)
    }

    /// A formatted amount less its digits, separators, spaces and direction
    /// marks.
    private static func symbolText(in formatted: String, locale: Locale) -> String {
        let numeric = CharacterSet.decimalDigits
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "\u{00A0}\u{202F}"))
            .union(CharacterSet(charactersIn: (locale.decimalSeparator ?? ".") + (locale.groupingSeparator ?? ",")))
        return String(String.UnicodeScalarView(formatted.unicodeScalars.filter {
            !numeric.contains($0) && !isFormatMark($0)
        }))
    }

    /// An invisible mark such as Arabic formats put around numbers to keep
    /// them left to right (U+200F, U+061C).
    private static func isFormatMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format
    }

    /// The decimal places of an amount in the currency, as `format` writes
    /// it: 2 for US dollars, 0 for yen. At most 3, a milliunit.
    static func fractionDigits(currencyCode: String, locale: Locale = .current) -> Int {
        // Zero is written with one whole digit: "0.00", or "0" for yen.
        let digits = formatNumber(0, currencyCode: currencyCode, locale: locale).filter(\.isWholeNumber).count
        return min(max(digits - 1, 0), 3)
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

    /// Reads an amount the user typed: a number or a formula such as
    /// `12.50+3*2` (`AmountFormula`), with or without grouping separators and
    /// the currency's symbols, which are ignored. The result is rounded half
    /// away from zero to the currency's decimal places, so it's what `format`
    /// shows. Empty text is 0. Returns `nil` for anything that isn't a number
    /// or a formula, or is beyond SPEC 3.7's limit.
    static func parse(_ text: String, currencyCode: String, locale: Locale = .current) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }

        // A symbol becomes a space, so "5$3" is two numbers, not 53.
        let bare = symbols(currencyCode: currencyCode, locale: locale)
            .reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
        guard var value = AmountFormula.evaluate(bare, locale: locale) else { return nil }

        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, fractionDigits(currencyCode: currencyCode, locale: locale), .plain)
        let milliunits = rounded * 1000
        guard abs(milliunits) <= Decimal(limit) else { return nil }
        return Int(truncating: NSDecimalNumber(decimal: milliunits))
    }

    /// The ways the currency may be written beside an amount, longest first:
    /// the standard symbol ("US$" in Canada), the narrow one ("$") and the
    /// code ("USD").
    private static func symbols(currencyCode: String, locale: Locale) -> [String] {
        let standard = symbolText(in: format(0, currencyCode: currencyCode, locale: locale), locale: locale)
        let narrow = symbol(currencyCode: currencyCode, locale: locale).text
        return Set([standard, narrow, currencyCode])
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }
}
