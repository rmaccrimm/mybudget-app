import Foundation

/// The arithmetic an amount field accepts: numbers as `locale` writes them,
/// `+`, `-`, `*` and `/` (or `−`, `×` and `÷`), parentheses, and signs before
/// a number or parenthesis, as in `-(12.50+3)*2` or `4*-2`. `*` and `/` bind
/// tighter than `+` and `-`, and operators of the same kind go left to right,
/// so `10-2-3` is 5. Spaces between numbers and operators are ignored.
enum AmountFormula {
    /// How deeply parentheses may nest: `((1))` is 2 deep.
    static let maxDepth = 10
    /// The longest formula, in characters.
    static let maxLength = 200

    /// The exact value of `text`, or `nil` if it isn't a formula, divides by
    /// zero, or is beyond what `Decimal` holds.
    static func evaluate(_ text: String, locale: Locale = .current) -> Decimal? {
        guard text.count <= maxLength, let tokens = tokens(in: text, locale: locale) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.sum(depth: 0), parser.isAtEnd else { return nil }
        return value
    }

    // MARK: Tokens

    private enum Token: Equatable {
        case number(Decimal)
        case plus, minus, times, divide, open, close
    }

    private static func tokens(in text: String, locale: Locale) -> [Token]? {
        let separators = Separators(locale: locale)
        var tokens: [Token] = []
        var number = ""

        /// Ends the number being read, if any.
        func endNumber() -> Bool {
            guard !number.isEmpty else { return true }
            defer { number = "" }
            guard let value = separators.value(of: number) else { return false }
            tokens.append(.number(value))
            return true
        }

        for character in text {
            // A space continues a number only where spaces group digits,
            // as in French "1 234,56".
            if isDigit(character) || character == separators.decimal
                || (separators.isGrouping(character) && (!character.isWhitespace || !number.isEmpty)) {
                number.append(character)
                continue
            }
            guard endNumber() else { return nil }
            switch character {
            case "+": tokens.append(.plus)
            case "-", "−": tokens.append(.minus)
            case "*", "×": tokens.append(.times)
            case "/", "÷": tokens.append(.divide)
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default:
                // Formatted amounts carry direction marks in some locales.
                guard character.isWhitespace || isFormatMark(character) else { return nil }
            }
        }
        guard endNumber() else { return nil }
        return tokens
    }

    /// A decimal digit in any script, such as "7" or Arabic "٧".
    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.first!.properties.numericType == .decimal
    }

    private static func isFormatMark(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
    }

    /// How `locale` writes numbers. A number is checked here rather than by
    /// the locale's parser, which reads "12abc" as 12.
    private struct Separators {
        let decimal: Character
        let grouping: Character?

        init(locale: Locale) {
            decimal = locale.decimalSeparator?.first ?? "."
            grouping = locale.groupingSeparator?.first
        }

        /// Any space counts as a grouping separator where the locale groups
        /// digits with one, since that space is hard to type.
        func isGrouping(_ character: Character) -> Bool {
            guard let grouping else { return false }
            return character == grouping || (grouping.isWhitespace && character.isWhitespace)
        }

        /// Digits with grouping separators between whole digits and at most
        /// one decimal separator: "1,234.5", ".5" and "5." in English.
        func value(of text: String) -> Decimal? {
            let text = text.trimmingCharacters(in: .whitespaces)
            var whole = "", fraction = ""
            var inFraction = false
            var afterGrouping = false
            for character in text {
                if AmountFormula.isDigit(character) {
                    let digit = String(character.wholeNumberValue!)
                    if inFraction { fraction += digit } else { whole += digit }
                    afterGrouping = false
                } else if character == decimal, !inFraction, !afterGrouping {
                    inFraction = true
                } else if isGrouping(character), !inFraction, !whole.isEmpty, !afterGrouping {
                    afterGrouping = true
                } else {
                    return nil
                }
            }
            guard !afterGrouping, !(whole.isEmpty && fraction.isEmpty) else { return nil }
            let plain = (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction)
            return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    // MARK: Parsing

    /// Reads `sum` by recursive descent. Only parentheses recurse, so
    /// `maxDepth` bounds the recursion.
    private struct Parser {
        let tokens: [Token]
        var index = 0

        var isAtEnd: Bool { index == tokens.count }
        private var next: Token? { isAtEnd ? nil : tokens[index] }

        /// Terms joined by `+` and `-`.
        mutating func sum(depth: Int) -> Decimal? {
            guard var value = product(depth: depth) else { return nil }
            while let token = next, token == .plus || token == .minus {
                index += 1
                guard let term = product(depth: depth) else { return nil }
                value = token == .plus ? value + term : value - term
                guard !value.isNaN else { return nil }
            }
            return value
        }

        /// Factors joined by `*` and `/`.
        mutating func product(depth: Int) -> Decimal? {
            guard var value = factor(depth: depth) else { return nil }
            while let token = next, token == .times || token == .divide {
                index += 1
                guard let factor = factor(depth: depth) else { return nil }
                if token == .divide {
                    guard !factor.isZero else { return nil }
                    value /= factor
                } else {
                    value *= factor
                }
                guard !value.isNaN else { return nil }
            }
            return value
        }

        /// A number or a parenthesized sum, after any signs.
        mutating func factor(depth: Int) -> Decimal? {
            var negative = false
            while let token = next, token == .plus || token == .minus {
                index += 1
                if token == .minus { negative.toggle() }
            }
            guard let token = next else { return nil }
            index += 1
            let value: Decimal
            switch token {
            case .number(let number):
                value = number
            case .open:
                guard depth < AmountFormula.maxDepth,
                      let inner = sum(depth: depth + 1),
                      next == .close
                else { return nil }
                index += 1
                value = inner
            default:
                return nil
            }
            guard !value.isNaN else { return nil }
            return negative ? -value : value
        }
    }
}
