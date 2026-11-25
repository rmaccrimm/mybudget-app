import SwiftUI

/// Sets or removes a category's target (SPEC 18.3, 18.4).
struct TargetSheet: View {
    let plan: PlanModel
    let category: Category

    @Environment(\.dismiss) private var dismiss
    @State private var kind: BudgetTarget.Kind
    @State private var amountText: String
    /// A day 1 to 31, or `nil` for the last day of the month.
    @State private var dueDay: Int?
    @State private var startMonth: BudgetMonth
    @State private var saving = false
    @State private var error: String?

    init(plan: PlanModel, category: Category) {
        self.plan = plan
        self.category = category
        let current = category.target
        _kind = State(initialValue: current?.type ?? .refill)
        _amountText = State(
            initialValue: current.map { Money.formatNumber($0.amount, currencyCode: plan.currencyCode) } ?? ""
        )
        _dueDay = State(initialValue: current?.byDate)
        _startMonth = State(
            initialValue: TargetInput.defaultStartMonth(viewing: plan.selectedMonth, current: .current())
        )
    }

    private var amount: Int? {
        guard let value = Money.parse(amountText, currencyCode: plan.currencyCode), value > 0 else { return nil }
        return value
    }

    private var startMonths: [BudgetMonth] {
        let now = BudgetMonth.current()
        return BudgetMonth.range(from: now, through: max(now.adding(months: 36), startMonth))
    }

    /// SPEC 18.4: the new target removes every later one.
    private var replacedStart: BudgetMonth? {
        guard let start = category.target.flatMap({ BudgetMonth(key: $0.startMonth) }),
              start > startMonth else { return nil }
        return start
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(BudgetTarget.Kind.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Amount") {
                    AmountField(
                        "Amount", text: $amountText, currencyCode: plan.currencyCode,
                        prompt: Money.formatNumber(0, currencyCode: plan.currencyCode)
                    )
                }
                Picker("Due", selection: $dueDay) {
                    Text("Last day of month").tag(Int?.none)
                    Divider()
                    ForEach(1...31, id: \.self) { Text("Day \($0)").tag(Int?.some($0)) }
                }
                Picker("Starting", selection: $startMonth) {
                    ForEach(startMonths) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Target for \(category.name)").font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .setAside
                         ? "Assign this amount every month."
                         : "Fill the category up to this amount every month.")
                        .foregroundStyle(.secondary)
                    if amount == nil {
                        Text("Enter an amount greater than 0.").foregroundStyle(.red)
                    }
                    if let replacedStart {
                        Label("This replaces the target starting \(replacedStart.title)",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if category.target != nil {
                Section {
                    Button("Remove Target", role: .destructive, action: remove)
                } footer: {
                    Text("Removes the target from \(BudgetMonth.current().title) onward")
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(amount == nil || saving)
            }
        }
    }

    private func save() {
        guard let amount else { return }
        run(TargetInput(type: kind, amount: amount, byDate: dueDay, startMonth: startMonth.key))
    }

    private func remove() { run(nil) }

    private func run(_ target: TargetInput?) {
        saving = true
        error = nil
        Task {
            do {
                try await plan.setTarget(target, categoryID: category.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
