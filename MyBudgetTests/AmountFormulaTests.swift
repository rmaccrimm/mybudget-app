import Foundation
import Testing
@testable import MyBudget

struct AmountFormulaTests {
    private let us = Locale(identifier: "en_US")

    private func parse(_ text: String, _ currencyCode: String = "USD", locale: Locale? = nil) -> Int? {
        Money.parse(text, currencyCode: currencyCode, locale: locale ?? us)
    }

    @Test(arguments: [
        ("12.50+3", 15_500),
        ("2+3*4", 14_000),
        ("(2+3)*4", 20_000),
        ("10-2-3", 5_000),
        ("100/4/5", 5_000),
        ("-(2+3)", -5_000),
        ("4*-2", -8_000),
        ("5--3", 8_000),
        ("+5", 5_000),
        ("((1+2)*(3+4))/7", 3_000),
        (" 12.50 + 3 ", 15_500),
        ("$10+$5", 15_000),
        ("1,234.56+0.44", 1_235_000),
        (".5+5.", 5_500),
        ("10×2÷4−1", 4_000),
        ("0.1+0.2", 300),
        ("10-25", -15_000),
    ])
    func evaluatesFormulas(text: String, milliunits: Int) {
        #expect(parse(text) == milliunits)
    }

    @Test func roundsTheResultToTheCurrencysDecimalPlaces() {
        #expect(parse("100/3") == 33_330)
        #expect(parse("-100/3") == -33_330)
        #expect(parse("2/3") == 670)
        #expect(parse("0.125*1") == 130)
        #expect(parse("100/3", "JPY") == 33_000)
        #expect(parse("100/3", "BHD") == 33_333)
        #expect(Money.fractionDigits(currencyCode: "USD", locale: us) == 2)
        #expect(Money.fractionDigits(currencyCode: "JPY", locale: us) == 0)
        #expect(Money.fractionDigits(currencyCode: "BHD", locale: us) == 3)
    }

    @Test(arguments: [
        "1/0", "1/(2-2)", "2+", "*2", "2*", "()", "(1", "1)", "(1))", "2(3)", "(2)3",
        "1 2", "1+abc", "2^3", "1e3", "5%",
    ])
    func rejectsWhatIsntAFormula(text: String) {
        #expect(parse(text) == nil)
    }

    @Test func limitsNestingAndLength() {
        func nested(_ depth: Int) -> String {
            String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        }
        #expect(parse(nested(AmountFormula.maxDepth)) == 1_000)
        #expect(parse(nested(AmountFormula.maxDepth + 1)) == nil)

        let longest = "1" + String(repeating: "+1", count: (AmountFormula.maxLength - 1) / 2)
        #expect(longest.count == AmountFormula.maxLength - 1)
        #expect(parse(longest) == (longest.count + 1) / 2 * 1_000)
        #expect(parse(longest + "+1") == nil)
    }

    @Test func keepsTheResultWithinTheLimit() {
        #expect(parse("1000000000*1") == 1_000_000_000_000)
        #expect(parse("-500000000*2") == -1_000_000_000_000)
        #expect(parse("1000000000+0.01") == nil)
        #expect(parse("999999999*999999999") == nil)
        // Beyond Decimal's range on the way: an error, not a crash.
        let huge = "9" + String(repeating: "0", count: 100)
        #expect(parse("\(huge)*\(huge)/\(huge)") == nil)
    }

    @Test func readsTheLocalesSeparators() {
        let germany = Locale(identifier: "de_DE")
        #expect(parse("1.234,56+0,44", "EUR", locale: germany) == 1_235_000)
        #expect(parse("1,5*2", "EUR", locale: germany) == 3_000)
        let france = Locale(identifier: "fr_FR")
        #expect(parse("1 234,56 + 1", "EUR", locale: france) == 1_235_560)
        #expect(parse("2 * 3", "EUR", locale: france) == 6_000)
    }

    /// The field replaces a formula with `Money.formatNumber`'s text, which
    /// must read back as the same amount.
    @Test(arguments: [
        ("en_US", "USD"), ("en_CA", "USD"), ("de_DE", "EUR"), ("fr_FR", "EUR"),
        ("sv_SE", "SEK"), ("de_CH", "CHF"), ("nl_NL", "EUR"), ("ja_JP", "JPY"), ("ar_EG", "EGP"),
    ])
    func readsBackWhatItFormats(identifier: String, currencyCode: String) {
        let locale = Locale(identifier: identifier)
        for milliunits in [0, 1_230_000, -1_234_000, 999_999_000_000] {
            let text = Money.formatNumber(milliunits, currencyCode: currencyCode, locale: locale)
            #expect(Money.parse(text, currencyCode: currencyCode, locale: locale) == milliunits, "\(text)")
            if abs(milliunits) * 2 <= Money.limit {
                #expect(Money.parse(text + "+" + text, currencyCode: currencyCode, locale: locale) == 2 * milliunits, "\(text)")
            }
        }
    }
}
