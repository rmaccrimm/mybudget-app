import SwiftUI

/// An account's transactions, newest first, or every account's when
/// `accountID` is `nil`.
struct RegisterView: View {
    let plan: PlanModel
    let accountID: Account.ID?
    @Binding var editor: TransactionEditor?

    @State private var selection = Set<Transaction.ID>()
    @State private var deleting: [Transaction]?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            BalanceBar(plan: plan, accounts: accounts)
            Divider()
            table
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .add(accountID)
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .help("Add Transaction (⌘N)")
                .disabled(plan.accounts.isEmpty)
            }
        }
        .onChange(of: accountID) { selection = [] }
        .onChange(of: plan.transactions) {
            selection.formIntersection(plan.transactions.map(\.id))
        }
        .confirmationDialog(
            deletingTitle,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { transactions in
            Button("Delete", role: .destructive) {
                run { try await plan.delete(transactions) }
            }
        } message: { transactions in
            if transactions.contains(where: \.isTransfer) {
                Text("Deleting a transfer also deletes its other half.")
            }
        }
        .alert(
            "Couldn't Change the Transactions",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
        } message: { message in
            Text(message)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                FlagMark(color: row.transaction.flagColor)
            }
            .width(16)

            if accountID == nil {
                TableColumn("Account") { row in
                    Text(plan.account(id: row.transaction.accountId)?.name ?? "")
                }
                .width(min: 70, ideal: 100)
            }

            TableColumn("Date") { row in
                Text(PlanDate.display(row.transaction.date)).monospacedDigit()
            }
            .width(min: 76, ideal: 84)

            TableColumn("Payee") { row in
                Text(plan.payeeName(row.transaction.payeeId))
            }
            .width(min: 80, ideal: 110)

            TableColumn("Category") { row in
                CategoryCell(plan: plan, transaction: row.transaction)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Memo") { row in
                Text(row.transaction.memo ?? "").foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("Outflow") { row in
                AmountCell(amount: row.transaction.amount < 0 ? -row.transaction.amount : nil, currencyCode: plan.currencyCode)
            }
            .width(min: 90, ideal: 110)
            .alignment(.trailing)

            TableColumn("Inflow") { row in
                AmountCell(amount: row.transaction.amount > 0 ? row.transaction.amount : nil, currencyCode: plan.currencyCode)
            }
            .width(min: 90, ideal: 110)
            .alignment(.trailing)

            if accountID != nil {
                TableColumn("Balance") { row in
                    if let balance = row.runningBalance {
                        Text(Money.format(balance, currencyCode: plan.currencyCode))
                            .monospacedDigit()
                            .foregroundStyle(balance < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }
                .width(min: 90, ideal: 110)
                .alignment(.trailing)
            }

            TableColumn("") { row in
                ClearedButton(state: row.transaction.cleared) {
                    toggleCleared([row.transaction])
                }
            }
            .width(24)
        }
        .contextMenu(forSelectionType: Transaction.ID.self) { ids in
            menu(for: transactions(ids))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first {
                editor = .edit(id)
            }
        }
        .onDeleteCommand {
            let selected = transactions(selection)
            if !selected.isEmpty { deleting = selected }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Transactions", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(plan.accounts.isEmpty
                         ? "Add an account first."
                         : "Add what you've spent and received to see it here.")
                } actions: {
                    if !plan.accounts.isEmpty {
                        Button("Add Transaction") { editor = .add(accountID) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for transactions: [Transaction]) -> some View {
        if transactions.count == 1, let transaction = transactions.first {
            Button("Edit Transaction…") { editor = .edit(transaction.id) }
            Divider()
        }
        if !transactions.isEmpty {
            let changeable = transactions.filter { $0.cleared != .reconciled }
            Button("Mark as Cleared") { setCleared(changeable, .cleared) }
                .disabled(!changeable.contains { $0.cleared == .uncleared })
            Button("Mark as Uncleared") { setCleared(changeable, .uncleared) }
                .disabled(!changeable.contains { $0.cleared == .cleared })
            Menu("Flag") {
                ForEach(FlagColor.allCases) { color in
                    Button(color.title) { setFlag(transactions, color) }
                }
                Divider()
                Button("Remove Flag") { setFlag(transactions, nil) }
            }
            Divider()
            Button(transactions.count == 1 ? "Delete Transaction…" : "Delete \(transactions.count) Transactions…",
                   role: .destructive) {
                deleting = transactions
            }
        }
    }

    // MARK: Data

    private var rows: [RegisterRow] {
        RegisterRow.rows(plan.transactions, accountID: accountID)
    }

    /// The accounts whose balances the bar adds up.
    private var accounts: [Account] {
        guard let accountID else { return plan.accounts }
        return plan.account(id: accountID).map { [$0] } ?? []
    }

    /// In the register's order.
    private func transactions(_ ids: Set<Transaction.ID>) -> [Transaction] {
        rows.map(\.transaction).filter { ids.contains($0.id) }
    }

    private var deletingTitle: String {
        guard let deleting else { return "" }
        return deleting.count == 1 ? "Delete this transaction?" : "Delete \(deleting.count) transactions?"
    }

    // MARK: Actions

    /// The cleared button switches between cleared and uncleared. A
    /// reconciled transaction stays as it is.
    private func toggleCleared(_ transactions: [Transaction]) {
        run {
            try await plan.update(transactions) { transaction in
                switch transaction.cleared {
                case .uncleared: TransactionPatch(cleared: .cleared)
                case .cleared: TransactionPatch(cleared: .uncleared)
                case .reconciled: nil
                }
            }
        }
    }

    private func setCleared(_ transactions: [Transaction], _ state: ClearedState) {
        run {
            try await plan.update(transactions) { $0.cleared == state ? nil : TransactionPatch(cleared: state) }
        }
    }

    private func setFlag(_ transactions: [Transaction], _ color: FlagColor?) {
        run {
            try await plan.update(transactions) {
                $0.flagColor == color ? nil : TransactionPatch(flagColor: .some(color))
            }
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Cleared, uncleared and working balances (SPEC 5.4), as YNAB shows them
/// above a register.
private struct BalanceBar: View {
    let plan: PlanModel
    let accounts: [Account]

    var body: some View {
        HStack(spacing: 14) {
            figure("Cleared", accounts.reduce(0) { $0 + $1.clearedBalance })
            Text("+").foregroundStyle(.tertiary)
            figure("Uncleared", accounts.reduce(0) { $0 + $1.unclearedBalance })
            Text("=").foregroundStyle(.tertiary)
            figure("Working Balance", accounts.reduce(0) { $0 + $1.balance })
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func figure(_ title: String, _ amount: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Money.format(amount, currencyCode: plan.currencyCode))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(amount < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CategoryCell: View {
    let plan: PlanModel
    let transaction: Transaction

    var body: some View {
        if transaction.isSplit {
            Text("Split (\(transaction.subtransactions.count))")
                .foregroundStyle(.secondary)
                .help(transaction.subtransactions.map {
                    "\(plan.categoryName($0.categoryId)): \(Money.format($0.amount, currencyCode: plan.currencyCode))"
                }.joined(separator: "\n"))
        } else if transaction.categoryId == nil, transaction.isTransfer {
            Text("Transfer").foregroundStyle(.secondary)
        } else {
            Text(plan.categoryName(transaction.categoryId))
        }
    }
}

private struct AmountCell: View {
    let amount: Int?
    let currencyCode: String

    var body: some View {
        if let amount {
            Text(Money.format(amount, currencyCode: currencyCode)).monospacedDigit()
        }
    }
}

private struct FlagMark: View {
    let color: FlagColor?

    var body: some View {
        if let color {
            Image(systemName: "flag.fill")
                .foregroundStyle(color.color)
                .help("\(color.title) flag")
        }
    }
}

/// YNAB's "C" column: green when cleared, a lock once reconciled.
private struct ClearedButton: View {
    let state: ClearedState
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            switch state {
            case .uncleared:
                Image(systemName: "c.circle").foregroundStyle(.tertiary)
            case .cleared:
                Image(systemName: "c.circle.fill").foregroundStyle(.green)
            case .reconciled:
                Image(systemName: "lock.fill").foregroundStyle(.green)
            }
        }
        .buttonStyle(.borderless)
        .disabled(state == .reconciled)
        .help(help)
    }

    private var help: String {
        switch state {
        case .uncleared: "Uncleared: click to mark as cleared"
        case .cleared: "Cleared: click to mark as uncleared"
        case .reconciled: "Reconciled"
        }
    }
}
