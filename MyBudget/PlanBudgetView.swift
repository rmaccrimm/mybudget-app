import SwiftUI

/// The Plan page: each category's target, assigned, activity and available
/// for the selected month, under the month's totals.
struct PlanBudgetView: View {
    let plan: PlanModel

    @State private var selectedCategoryID: Category.ID?
    @State private var targetEditor: Category?
    @State private var categoryEditor: CategoryEditor?
    @State private var deleting: Category?
    @State private var showingMonthPicker = false
    @State private var loadError: String?
    @State private var actionError: String?

    private var currency: String { plan.currencyCode }

    /// The months the page can reach: back without limit, forward two months
    /// past the current one.
    private var navigable: ClosedRange<BudgetMonth> { BudgetMonth.navigableMonths() }

    var body: some View {
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
                    plan.selectMonth(plan.selectedMonth.adding(months: -1))
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(plan.selectedMonth <= navigable.lowerBound)
                .help("Previous Month")

                Button {
                    showingMonthPicker = true
                } label: {
                    Text(plan.selectedMonth.title)
                        .font(.headline)
                        .monospacedDigit()
                        .frame(minWidth: 130)
                }
                .help("Choose a month")
                .popover(isPresented: $showingMonthPicker, arrowEdge: .bottom) {
                    MonthPicker(selection: plan.selectedMonth, range: navigable) { month in
                        plan.selectMonth(month)
                        showingMonthPicker = false
                    }
                }

                Button {
                    plan.selectMonth(plan.selectedMonth.adding(months: 1))
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(plan.selectedMonth >= navigable.upperBound)
                .help("Next Month")

                Button("Today") { plan.selectMonth(.current()) }
                    .help("Go to the current month")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Category", action: addCategory)
                    .help("Add a category")

                Button {
                    targetEditor = selectedCategory
                } label: {
                    Text("Set Target")
                }
                .disabled(selectedCategory == nil || selectedCategory?.paymentAccountId != nil)
                .help("Set or remove the selected category's target")
            }
        }
        .task(id: plan.selectedMonth) { await load() }
        .sheet(item: $targetEditor) { category in
            TargetSheet(plan: plan, category: category)
        }
        .sheet(item: $categoryEditor) { editor in
            CategorySheet(plan: plan, editor: editor)
        }
        .sheet(item: $deleting) { category in
            DeleteCategorySheet(plan: plan, category: category)
        }
        .onChange(of: plan.categoryGroups) {
            // The selected category was deleted.
            if let id = selectedCategoryID, plan.categoriesByID[id] == nil {
                selectedCategoryID = nil
            }
        }
        .alert(
            "Couldn't Change the Plan",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
        } message: {
            Text(actionError ?? "")
        }
    }

    private func addCategory() {
        categoryEditor = .add(defaultGroup: selectedCategory?.groupId)
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
                                onEdit: { categoryEditor = .edit(category) },
                                onDelete: { deleting = category },
                                onAssign: { amount in assign(amount, to: category) }
                            )
                            Divider()
                        }
                    } header: {
                        GroupRow(
                            name: group.name,
                            entries: categories.compactMap { plan.month?.entry(for: $0.id) },
                            currencyCode: currency,
                            // The payment group gets its categories from
                            // credit accounts only.
                            onAddCategory: group.internal
                                ? nil
                                : { categoryEditor = .add(defaultGroup: group.id) }
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
    /// Adds a category to this group; `nil` for a group the user can't add to.
    var onAddCategory: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(name).font(.headline)
                if let onAddCategory {
                    Button(action: onAddCategory) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a category to \(name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(Money.format(value, currencyCode: currencyCode, narrow: true))
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
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onAssign: (Int) -> Void

    private var isPayment: Bool { category.paymentAccountId != nil }

    var body: some View {
        HStack(spacing: 12) {
            Text(category.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if isPayment {
                    Text("")
                } else if let status = entry?.targetStatus(currencyCode: currencyCode) {
                    Button(action: onTarget) {
                        switch status {
                        case .underfunded(let text):
                            Text(text).foregroundStyle(.yellow)
                        case .funded:
                            Text("Funded").foregroundStyle(.green)
                        }
                    }
                    .buttonStyle(.plain)
                    .lineLimit(1)
                    .help("Edit the target")
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
                Text(Money.format(entry.activity, currencyCode: currencyCode, narrow: true))
                    .monospacedDigit()
                    .frame(width: Column.amount, alignment: .trailing)
                Text(Money.format(entry.available, currencyCode: currencyCode, narrow: true))
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
        .contextMenu {
            // Payment categories go only with their account (SPEC 13.1).
            if !isPayment {
                Button("Edit Category…", action: onEdit)
                Button("Set Target…", action: onTarget)
                Divider()
                Button("Delete Category…", role: .destructive, action: onDelete)
            }
        }
    }
}

/// An amount edited in place: committed on Return or when focus leaves.
/// The currency symbol sits beside the number rather than in the text, and
/// greys out while editing.
private struct AssignedField: View {
    let value: Int
    let currencyCode: String
    var onCommit: (Int) -> Void

    @State private var text = ""
    /// The amount shown while not editing; ahead of `value` until the
    /// server's answer arrives.
    @State private var shown = 0
    @FocusState private var focused: Bool

    private var symbol: (text: String, leads: Bool) { Money.symbol(currencyCode: currencyCode) }

    var body: some View {
        let symbol = symbol
        HStack(spacing: symbol.leads ? 0 : 3) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .overlay(alignment: .trailing) {
                    if symbol.leads {
                        // The symbol just left of the number: the hidden text
                        // takes the number's width.
                        HStack(spacing: 0) {
                            symbolText(!focused && shown < 0 ? "-" + symbol.text : symbol.text)
                            Text(text.isEmpty ? " " : text).hidden()
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
        .onTapGesture { focused = true }
        .onAppear { show(value) }
        .onChange(of: value) { if !focused { show(value) } }
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                text = Money.formatNumber(shown, currencyCode: currencyCode)
            } else {
                commit()
            }
        }
    }

    private func symbolText(_ text: String) -> some View {
        Text(text).foregroundStyle(focused ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
    }

    /// Shows `amount`. With the symbol in front, a negative amount's sign goes
    /// before the symbol while not editing: "-$5.00", not "$-5.00".
    private func show(_ amount: Int) {
        shown = amount
        let signless = !focused && symbol.leads
        text = Money.formatNumber(signless ? abs(amount) : amount, currencyCode: currencyCode)
    }

    private func commit() {
        guard let parsed = Money.parse(text, currencyCode: currencyCode) else {
            show(value)
            return
        }
        if parsed != value { onCommit(parsed) }
        show(parsed)
    }
}

private struct HeaderBar: View {
    let month: MonthBudget
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to Assign").font(.caption).foregroundStyle(.secondary)
                Text(Money.format(month.readyToAssign, currencyCode: currencyCode, narrow: true))
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
            Text(Money.format(value, currencyCode: currencyCode, narrow: true)).monospacedDigit()
        }
    }
}
