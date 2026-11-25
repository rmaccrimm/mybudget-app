import SwiftUI

/// The field for every amount the user types. It takes a number or a formula
/// such as `12.50+3*2` (`AmountFormula`), and on Return or when focus leaves
/// it replaces the text with the result, as `Money.formatNumber` writes it.
///
/// The currency symbol sits beside the number rather than in the text, so
/// it can't be edited, and it greys out while editing or while the field is
/// empty. With the symbol in front, a negative amount reads "-$5.00" while
/// not editing, not "$-5.00".
///
/// `text` holds what was typed, sign included, so the owner can read the
/// amount with `Money.parse` at any time, even before a formula is replaced.
/// Text that isn't an amount stays as it was typed.
struct AmountField: View {
    private let title: String
    @Binding private var text: String
    private let currencyCode: String
    private let prompt: String?
    private let focus: FocusState<Bool>.Binding?
    private let onCommit: (Int?) -> Void

    @FocusState private var ownFocus: Bool
    @Environment(\.isEnabled) private var isEnabled

    /// - Parameters:
    ///   - title: The field's accessibility label; it isn't shown.
    ///   - focus: Focus the owner tracks; the field keeps its own otherwise.
    ///   - onCommit: Called on Return or when focus leaves, after any formula
    ///     is replaced, with the amount (0 for empty text), or `nil` if the
    ///     text isn't an amount.
    init(
        _ title: String,
        text: Binding<String>,
        currencyCode: String,
        prompt: String? = nil,
        focus: FocusState<Bool>.Binding? = nil,
        onCommit: @escaping (Int?) -> Void = { _ in }
    ) {
        self.title = title
        _text = text
        self.currencyCode = currencyCode
        self.prompt = prompt
        self.focus = focus
        self.onCommit = onCommit
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }
    private var focused: Bool { focusBinding.wrappedValue }

    var body: some View {
        let symbol = Money.symbol(currencyCode: currencyCode)
        let signBeforeSymbol = symbol.leads && !focused && isNegative
        let shown = shownText(signBeforeSymbol: signBeforeSymbol)
        HStack(spacing: symbol.leads ? 0 : 3) {
            TextField(
                title,
                // Read live, not `shown`: the field may read it between updates.
                // Only editing writes: as focus leaves, the field may hand back
                // the shown text, which lacks the sign the symbol shows.
                text: Binding(
                    get: { shownText(signBeforeSymbol: symbol.leads && !focused && isNegative) },
                    set: { if focused { text = $0 } }
                ),
                prompt: prompt.map { Text(verbatim: $0) }
            )
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .focused(focusBinding)
            // Not `onSubmit`, which keeps Return from a sheet's default
            // button: Return evaluates, then still presses Save.
            .onKeyPress(.return) {
                commit()
                return .ignored
            }
            .overlay(alignment: .trailing) {
                if symbol.leads {
                    // The symbol just left of the number: the hidden text
                    // takes the number's width.
                    HStack(spacing: 0) {
                        symbolText(signBeforeSymbol ? "-" + symbol.text : symbol.text)
                        Text(verbatim: shown.isEmpty ? (prompt ?? " ") : shown).hidden()
                    }
                    .allowsHitTesting(false)
                }
            }
            if !symbol.leads {
                symbolText(symbol.text)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            if focused {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5).inset(by: -2))
        .contentShape(Rectangle())
        .onTapGesture { focusBinding.wrappedValue = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    /// What the text field shows: `text`, less a leading minus the symbol
    /// shows instead.
    private func shownText(signBeforeSymbol: Bool) -> String {
        signBeforeSymbol ? String(text.dropFirst()) : text
    }

    /// Whether the text is a negative amount as `Money.formatNumber` writes
    /// it, with a leading minus; not a formula such as "-(10+5)".
    private var isNegative: Bool {
        guard let first = text.first, first == "-" || first == "−",
              let amount = Money.parse(text, currencyCode: currencyCode), amount < 0
        else { return false }
        return Money.formatNumber(amount, currencyCode: currencyCode) == text
    }

    private func symbolText(_ string: String) -> some View {
        let muted = focused || text.isEmpty || !isEnabled
        return Text(verbatim: string).foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }

    /// Replaces a number or formula with its result; empty text stays empty.
    private func commit() {
        let amount = Money.parse(text, currencyCode: currencyCode)
        if let amount, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            text = Money.formatNumber(amount, currencyCode: currencyCode)
        }
        onCommit(amount)
    }
}
