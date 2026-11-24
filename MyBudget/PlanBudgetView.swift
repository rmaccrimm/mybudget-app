import SwiftUI

/// The Plan page: each category's target, assigned, activity and available
/// for the selected month, under the month's totals.
struct PlanBudgetView: View {
    let plan: PlanModel

    @State private var selectedCategoryID: Category.ID?
    @State private var targetEditor: Category?
    @State private var loadError: String?
    @State private var actionError: String?

    private var currency: String { plan.currencyCode }

    var body: some View {
        @Bindable var plan = plan
        VStack(spacing: 0) {
            if let month = plan.month {
                HeaderBar(month: month, currencyCode: currency)
                Divider()
            }
            if let loadError {
                Text(loadError).foregroundStyle(.red).padding(8)
            }
            table
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    plan.selectedMonth = plan.selectedMonth.adding(months: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous Month")

                Text(plan.selectedMonth.title)
                    .font(.headline)
                    .monospacedDigit()
                    .frame(minWidth: 130)

                Button {
                    plan.selectedMonth = plan.selectedMonth.adding(months: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Next Month")

                Menu {
                    ForEach(pickerMonths) { month in
                        Button(month.title) { plan.selectedMonth = month }
                    }
                } label: {
                    Label("Jump to Month", systemImage: "calendar")
                }
                .help("Jump to a month")

                Button("Today") { plan.selectedMonth = .current() }
                    .help("Go to the current month")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    targetEditor = selectedCategory
                } label: {
                    Label("Target", systemImage: "target").labelStyle(.titleAndIcon)
                }
                .disabled(selectedCategory == nil || selectedCategory?.paymentAccountId != nil)
                .help("Set or remove the selected category's target")
            }
        }
        .task(id: plan.selectedMonth) { await load() }
        .sheet(item: $targetEditor) { category in
            TargetSheet(plan: plan, category: category)
        }
        .alert(
            "Couldn't Change the Plan",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Two years either side of the current month, and the selected month.
    private var pickerMonths: [BudgetMonth] {
        let now = BudgetMonth.current()
        var first = now.adding(months: -24)
        var last = now.adding(months: 24)
        first = min(first, plan.selectedMonth)
        last = max(last, plan.selectedMonth)
        return BudgetMonth.range(from: first, through: last)
    }

    private var selectedCategory: Category? {
        selectedCategoryID.flatMap { plan.categoriesByID[$0] }
    }

    private func load() async {
        do {
            try await plan.loadMonth()
            loadError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var visibleGroups: [CategoryGroup] {
        plan.categoryGroups.filter { !$0.hidden && !$0.categories.filter { !$0.hidden }.isEmpty }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ColumnHeader()
                ForEach(visibleGroups) { group in
                    let categories = group.categories.filter { !$0.hidden }
                    Section {
                        ForEach(categories) { category in
                            CategoryRow(
                                category: category,
                                entry: plan.month?.entry(for: category.id),
                                currencyCode: currency,
                                selected: selectedCategoryID == category.id,
                                onSelect: { selectedCategoryID = category.id },
                                onTarget: { targetEditor = category },
                                onAssign: { amount in assign(amount, to: category) }
                            )
                            Divider()
                        }
                    } header: {
                        GroupRow(
                            name: group.name,
                            entries: categories.compactMap { plan.month?.entry(for: $0.id) },
                            currencyCode: currency
                        )
                    }
                }
            }
        }
    }

    private func assign(_ amount: Int, to category: Category) {
        Task {
            do {
                try await plan.setAssigned(amount, categoryID: category.id)
            } catch {
                actionError = error.localizedDescription
                try? await plan.loadMonth()
            }
        }
    }
}

private enum Column {
    static let amount: CGFloat = 110
    static let target: CGFloat = 300
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Category").frame(maxWidth: .infinity, alignment: .leading)
            Text("Target").frame(width: Column.target, alignment: .leading)
            Text("Assigned").frame(width: Column.amount, alignment: .trailing)
            Text("Activity").frame(width: Column.amount, alignment: .trailing)
            Text("Available").frame(width: Column.amount, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct GroupRow: View {
    let name: String
    let entries: [MonthCategory]
    let currencyCode: String

    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: Column.target)
            amount(entries.reduce(0) { $0 + $1.assigned })
            amount(entries.reduce(0) { $0 + $1.activity })
            amount(entries.reduce(0) { $0 + $1.available }, red: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func amount(_ value: Int, red: Bool = false) -> some View {
        Text(Money.format(value, currencyCode: currencyCode))
            .monospacedDigit()
            .fontWeight(.semibold)
            .foregroundStyle(red && value < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .frame(width: Column.amount, alignment: .trailing)
    }
}

private struct CategoryRow: View {
    let category: Category
    let entry: MonthCategory?
    let currencyCode: String
    let selected: Bool
    var onSelect: () -> Void
    var onTarget: () -> Void
    var onAssign: (Int) -> Void

    private var isPayment: Bool { category.paymentAccountId != nil }

    var body: some View {
        HStack(spacing: 12) {
            Text(category.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if isPayment {
                    Text("")
                } else if let entry, entry.target != nil {
                    Button(entry.targetText(currencyCode: currencyCode), action: onTarget)
                        .buttonStyle(.link)
                        .lineLimit(1)
                } else {
                    Button("Set Target…", action: onTarget)
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(width: Column.target, alignment: .leading)

            if let entry {
                AssignedField(value: entry.assigned, currencyCode: currencyCode, onCommit: onAssign)
                    .frame(width: Column.amount)
                Text(Money.format(entry.activity, currencyCode: currencyCode))
                    .monospacedDigit()
                    .frame(width: Column.amount, alignment: .trailing)
                Text(Money.format(entry.available, currencyCode: currencyCode))
                    .monospacedDigit()
                    .foregroundStyle(entry.available < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .frame(width: Column.amount, alignment: .trailing)
            } else {
                Spacer().frame(width: Column.amount * 3 + 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// An amount edited in place: committed on Return or when focus leaves.
private struct AssignedField: View {
    let value: Int
    let currencyCode: String
    var onCommit: (Int) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear(perform: reset)
            .onChange(of: value) { if !focused { reset() } }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func reset() {
        text = Money.format(value, currencyCode: currencyCode)
    }

    private func commit() {
        guard let parsed = Money.parse(text, currencyCode: currencyCode) else {
            reset()
            return
        }
        if parsed != value { onCommit(parsed) }
        text = Money.format(parsed, currencyCode: currencyCode)
    }
}

private struct HeaderBar: View {
    let month: MonthBudget
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to Assign").font(.caption).foregroundStyle(.secondary)
                Text(Money.format(month.readyToAssign, currencyCode: currencyCode))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(month.readyToAssign < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            Spacer()
            stat("Left Over from Last Month", month.leftOverFromLastMonth)
            stat("Income", month.income)
            stat("Assigned", month.assigned)
            stat("Activity", month.activity)
            stat("Assigned in Future", month.assignedInFuture)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Money.format(value, currencyCode: currencyCode)).monospacedDigit()
        }
    }
}
