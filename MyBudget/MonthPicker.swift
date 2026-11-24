import SwiftUI

/// A calendar of months, a year at a time, for the Plan page's month. Months
/// outside `range` are shown but can't be chosen. The current month has an
/// outline and the selected month is filled.
struct MonthPicker: View {
    let selection: BudgetMonth
    let range: ClosedRange<BudgetMonth>
    var onPick: (BudgetMonth) -> Void

    @State private var year: Int

    init(selection: BudgetMonth, range: ClosedRange<BudgetMonth>, onPick: @escaping (BudgetMonth) -> Void) {
        self.selection = selection
        self.range = range
        self.onPick = onPick
        _year = State(initialValue: selection.year)
    }

    private var canGoBack: Bool { year > range.lowerBound.year }
    private var canGoForward: Bool { year < range.upperBound.year }

    var body: some View {
        let now = BudgetMonth.current()
        VStack(spacing: 12) {
            HStack {
                Button {
                    year -= 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Previous Year")

                Spacer()
                Text(String(year))
                    .font(.headline)
                    .monospacedDigit()
                Spacer()

                Button {
                    year += 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Next Year")
            }
            .buttonStyle(.borderless)

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<4, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            monthCell(month: row * 3 + column + 1, now: now)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func monthCell(month: Int, now: BudgetMonth) -> some View {
        let candidate = BudgetMonth(year: year, month: month)
        let enabled = range.contains(candidate)
        let selected = candidate == selection
        let isCurrent = candidate == now
        return Button {
            onPick(candidate)
        } label: {
            Text(Calendar.current.shortStandaloneMonthSymbols[month - 1])
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            selected ? AnyShapeStyle(.white) : (enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        )
        .background(
            RoundedRectangle(cornerRadius: 6).fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent && !selected ? Color.accentColor : .clear, lineWidth: 1)
        )
        .disabled(!enabled)
        .help(candidate.title)
    }
}
