import SwiftUI

/// What the transaction sheet is for.
enum TransactionEditor: Identifiable, Hashable {
    /// A new transaction, in the given account or one the sheet asks for.
    case add(Account.ID?)
    case edit(Transaction.ID)

    var id: Self { self }
}

/// Adds a transaction (SPEC 8.1) or edits one (SPEC 8.6).
struct TransactionSheet: View {
    let plan: PlanModel
    /// The transaction being edited, or `nil` for a new one.
    let original: Transaction?

    private enum Direction: Hashable { case outflow, inflow }

    @Environment(\.dismiss) private var dismiss
    @State private var accountID: Account.ID?
    @State private var date: Date
    @State private var payeeText: String
    @State private var categoryID: Category.ID?
    @State private var direction: Direction
    @State private var amountText: String
    @State private var memo: String
    @State private var cleared: Bool
    @State private var flag: FlagColor?
    @State private var creatingCategory = false
    @State private var saving = false
    @State private var error: String?
    /// What Save and Add Another just added, until the next save.
    @State private var added: String?
    @State private var payeeFocusRequest = 0

    /// The category the sheet started with, to tell whether it changed.
    private let initialCategoryID: Category.ID?

    init(plan: PlanModel, editor: TransactionEditor) {
        self.plan = plan
        switch editor {
        case .add(let accountID):
            let account = accountID.flatMap(plan.account(id:))
            original = nil
            initialCategoryID = nil
            _accountID = State(initialValue: accountID)
            _date = State(initialValue: .now)
            _payeeText = State(initialValue: "")
            _categoryID = State(initialValue: nil)
            _direction = State(initialValue: .outflow)
            _amountText = State(initialValue: "")
            _memo = State(initialValue: "")
            _cleared = State(initialValue: account.map { ClearedState.default(for: $0.type).isCleared } ?? false)
            _flag = State(initialValue: nil)
        case .edit(let id):
            let transaction = plan.transaction(id: id)
            original = transaction
            // SPEC 9.3: on a transfer between a budget and a tracking account,
            // the category is on the budget half, whichever half this is.
            let category = transaction?.categoryId
                ?? transaction?.transferTransactionId.flatMap(plan.transaction(id:))?.categoryId
            initialCategoryID = category
            _accountID = State(initialValue: transaction?.accountId)
            _date = State(initialValue: transaction.flatMap { PlanDate.date(from: $0.date) } ?? .now)
            _payeeText = State(initialValue: plan.payeeName(transaction?.payeeId))
            _categoryID = State(initialValue: category)
            _direction = State(initialValue: (transaction?.amount ?? 0) > 0 ? .inflow : .outflow)
            _amountText = State(initialValue: transaction.map {
                Money.format(abs($0.amount), currencyCode: plan.currencyCode)
            } ?? "")
            _memo = State(initialValue: transaction?.memo ?? "")
            _cleared = State(initialValue: transaction?.cleared.isCleared ?? false)
            _flag = State(initialValue: transaction?.flagColor)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            buttons
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $creatingCategory) {
            NewCategorySheet(plan: plan) { categoryID = $0.id }
        }
        .onChange(of: payeeChoice) {
            // As YNAB does, a known payee brings its last category to a new
            // transaction that has none yet.
            if original == nil, categoryID == nil, rule == .required,
               case .existing(let id) = payeeChoice {
                categoryID = plan.lastCategory(forPayee: id)
            }
        }
        .onChange(of: accountID) {
            if original == nil, let account {
                cleared = ClearedState.default(for: account.type).isCleared
            }
        }
    }

    /// A sheet's toolbar shows only one confirmation button, so the sheet
    /// draws its own row to fit Save and Add Another beside Save.
    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if original == nil {
                Button("Save and Add Another") { save(addingAnother: true) }
                    .help("Save and Add Another (⌘↩)")
                    .disabled(problem != nil || isIncomplete || saving)
                    .background {
                        // AppKit draws any button with a Return shortcut as
                        // the default button, so ⌘↩ lives on a hidden one.
                        Button("Save and Add Another") { save(addingAnother: true) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(problem != nil || isIncomplete || saving)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            }
            Button("Save") { save(addingAnother: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || isIncomplete || saving)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var form: some View {
        Form {
            Section {
                if original == nil {
                    Picker("Account", selection: $accountID) {
                        if accountID == nil {
                            Text("Choose an Account").tag(Account.ID?.none)
                        }
                        ForEach(AccountGroup.grouped(plan.accounts), id: \.group) { group, accounts in
                            Section(group.title) {
                                ForEach(accounts) { account in
                                    Label(account.name, systemImage: account.type.systemImage)
                                        .tag(Account.ID?.some(account.id))
                                }
                            }
                        }
                    }
                } else if let account {
                    LabeledContent("Account", value: account.name)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                LabeledContent("Payee") {
                    ComboBox(
                        text: $payeeText, items: payeeSuggestions, placeholder: "Optional",
                        focusRequest: payeeFocusRequest
                    )
                }
                category
            } header: {
                Text(original == nil ? "Add Transaction" : "Edit Transaction").font(.headline)
            } footer: {
                if let payeeNote {
                    Text(payeeNote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                LabeledContent("Amount") {
                    HStack {
                        Picker("Direction", selection: $direction) {
                            Text("Outflow").tag(Direction.outflow)
                            Text("Inflow").tag(Direction.inflow)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        TextField(
                            "Amount", text: $amountText,
                            prompt: Text(Money.format(0, currencyCode: plan.currencyCode))
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    }
                }
                .disabled(isSplit)
                TextField("Memo", text: $memo, prompt: Text("Optional"))
                if original?.cleared == .reconciled {
                    LabeledContent("Cleared", value: "Reconciled")
                } else {
                    Toggle("Cleared", isOn: $cleared)
                }
                Picker("Flag", selection: $flag) {
                    Text("None").tag(FlagColor?.none)
                    ForEach(FlagColor.allCases) { color in
                        Label(color.title, systemImage: "flag.fill")
                            .tint(color.color)
                            .tag(FlagColor?.some(color))
                    }
                }
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else if let added {
                    Label(added, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(saving)
    }

    @ViewBuilder
    private var category: some View {
        if let original, original.isSplit {
            LabeledContent("Category") {
                VStack(alignment: .trailing) {
                    ForEach(Array(original.subtransactions.enumerated()), id: \.offset) { _, part in
                        Text("\(plan.categoryName(part.categoryId))  \(Money.format(part.amount, currencyCode: plan.currencyCode))")
                    }
                    Text("Splits can't be changed here yet.").foregroundStyle(.secondary)
                }
            }
        } else {
            switch rule {
            case .required:
                LabeledContent("Category") {
                    HStack {
                        Picker("Category", selection: $categoryID) {
                            if categoryID == nil {
                                Text("Choose a Category").tag(Category.ID?.none)
                            }
                            Text("Inflow: Ready to Assign").tag(Category.ID?.some(Category.readyToAssign))
                            ForEach(plan.userCategoryGroups) { group in
                                let categories = group.categories.filter { !$0.hidden || $0.id == categoryID }
                                if !categories.isEmpty, !group.hidden || categories.contains(where: { $0.id == categoryID }) {
                                    Section(group.name) {
                                        ForEach(categories) { category in
                                            Text(category.name).tag(Category.ID?.some(category.id))
                                        }
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        Button {
                            creatingCategory = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("New Category…")
                    }
                }
            case .noneForTransfer:
                LabeledContent("Category", value: "None needed for a transfer")
                    .foregroundStyle(.secondary)
            case .noneForTracking:
                LabeledContent("Category", value: "Tracking accounts don't use categories")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Derived values

    private var account: Account? { accountID.flatMap(plan.account(id:)) }
    private var isSplit: Bool { original?.isSplit ?? false }

    /// Ordinary payees by name, then the transfer payees of the other
    /// accounts. A split can't be a transfer (SPEC 9.2).
    private var payeeSuggestions: [String] {
        let ordinary = plan.payees.filter { $0.transferAccountId == nil }
            .map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !isSplit else { return ordinary }
        let transfers = plan.accounts.filter { $0.id != accountID }
            .compactMap { plan.payeesByID[$0.transferPayeeId]?.name }
        return ordinary + transfers
    }

    private var payeeChoice: PayeeChoice {
        PayeeChoice.resolve(payeeText, in: plan.payees, ownAccount: accountID, allowTransfers: !isSplit)
    }

    private var transferAccount: Account? {
        guard case .existing(let id) = payeeChoice,
              let other = plan.payeesByID[id]?.transferAccountId
        else { return nil }
        return plan.account(id: other)
    }

    private var rule: CategoryRule {
        guard let account else { return .required }
        return CategoryRule.of(account: account, transferTo: transferAccount)
    }

    private var payeeNote: String? {
        if let transferAccount {
            return "A transfer also adds the opposite amount to “\(transferAccount.name)”."
        }
        if case .named(let name) = payeeChoice, NameRule.isValid(name, maxLength: NameRule.maxPayeeLength) {
            return "“\(name)” is a new payee."
        }
        return nil
    }

    /// The signed amount, or `nil` if the text isn't an amount.
    private var amount: Int? {
        if let original, original.isSplit { return original.amount }
        return Money.parse(amountText, currencyCode: plan.currencyCode).map {
            direction == .outflow ? -abs($0) : abs($0)
        }
    }

    private var clearedState: ClearedState {
        if original?.cleared == .reconciled { return .reconciled }
        return cleared ? .cleared : .uncleared
    }

    private var memoValue: String? { memo.isEmpty ? nil : memo }

    /// What's wrong with what was typed, if anything.
    private var problem: String? {
        if amount == nil {
            return "Enter an amount, such as \(Money.format(12_340, currencyCode: plan.currencyCode))."
        }
        if case .named(let name) = payeeChoice, !NameRule.isValid(name, maxLength: NameRule.maxPayeeLength) {
            return "A payee name can have at most \(NameRule.maxPayeeLength) characters."
        }
        if !NameRule.isValidNote(memo) {
            return "A memo can have at most \(NameRule.maxMemoLength) characters."
        }
        return nil
    }

    /// Whether something required is still empty: the account, the amount
    /// of a new transaction, or a category the account needs (SPEC 8.2).
    private var isIncomplete: Bool {
        account == nil
            || (original == nil && amountText.trimmingCharacters(in: .whitespaces).isEmpty)
            || (!isSplit && rule == .required && categoryID == nil)
    }

    // MARK: Saving

    private var newTransaction: NewTransaction? {
        guard let accountID, let amount else { return nil }
        return NewTransaction(
            accountId: accountID,
            date: PlanDate.string(from: date),
            amount: amount,
            payee: payeeChoice,
            categoryId: rule == .required ? categoryID : nil,
            memo: memoValue,
            cleared: clearedState,
            flagColor: flag
        )
    }

    /// Only what changed, so an unchanged transfer keeps its other half
    /// (SPEC 9.5) and an unchanged category stays where it is (SPEC 9.3).
    private func patch(for original: Transaction) -> TransactionPatch {
        var patch = TransactionPatch()
        let date = PlanDate.string(from: date)
        if date != original.date { patch.date = date }
        if let amount, amount != original.amount { patch.amount = amount }
        let originalPayee = original.payeeId.map(PayeeChoice.existing) ?? .none
        if payeeChoice != originalPayee { patch.payee = payeeChoice }
        if !original.isSplit, rule == .required, categoryID != initialCategoryID {
            patch.categoryId = .some(categoryID)
        }
        if memoValue != original.memo { patch.memo = .some(memoValue) }
        if clearedState != original.cleared { patch.cleared = clearedState }
        if flag != original.flagColor { patch.flagColor = .some(flag) }
        return patch
    }

    /// Saves, then closes the sheet or, `addingAnother`, empties it for the
    /// next transaction.
    private func save(addingAnother: Bool) {
        guard problem == nil, !isIncomplete else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if let original {
                    try await plan.update(original, patch(for: original))
                } else if let newTransaction {
                    let transaction = try await plan.addTransaction(newTransaction)
                    if addingAnother {
                        startAnother(after: transaction)
                        return
                    }
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Empties the sheet but keeps the account and date, since a batch of
    /// receipts is often from one account and one day.
    private func startAnother(after transaction: Transaction) {
        let payee = plan.payeeName(transaction.payeeId)
        let amount = Money.format(abs(transaction.amount), currencyCode: plan.currencyCode)
        let kind = transaction.amount > 0 ? "inflow" : "outflow"
        added = payee.isEmpty ? "Added an \(kind) of \(amount)." : "Added “\(payee)”, an \(kind) of \(amount)."
        error = nil
        payeeText = ""
        categoryID = nil
        direction = .outflow
        amountText = ""
        memo = ""
        flag = nil
        cleared = account.map { ClearedState.default(for: $0.type).isCleared } ?? false
        payeeFocusRequest += 1
    }
}

/// Creates a category (SPEC 7.5), in an existing group or a new one (SPEC 7.3).
struct NewCategorySheet: View {
    let plan: PlanModel
    var onAdded: (Category) -> Void

    private enum GroupTag: Hashable {
        case existing(CategoryGroup.ID)
        case new
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var group: GroupTag
    @State private var groupName = ""
    @State private var saving = false
    @State private var error: String?

    init(plan: PlanModel, onAdded: @escaping (Category) -> Void) {
        self.plan = plan
        self.onAdded = onAdded
        _group = State(initialValue: plan.userCategoryGroups.first.map { .existing($0.id) } ?? .new)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Groceries"))
                Picker("Group", selection: $group) {
                    ForEach(plan.userCategoryGroups) { group in
                        Text(group.name).tag(GroupTag.existing(group.id))
                    }
                    if !plan.userCategoryGroups.isEmpty {
                        Divider()
                    }
                    Text("New Group").tag(GroupTag.new)
                }
                if group == .new {
                    TextField("Group name", text: $groupName, prompt: Text("Everyday"))
                }
            } header: {
                Text("New Category").font(.headline)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Category", action: add)
                    .disabled(groupChoice == nil || !NameRule.isValid(name) || saving)
            }
        }
    }

    private var groupChoice: CategoryGroupChoice? {
        switch group {
        case .existing(let id): .existing(id)
        case .new: NameRule.isValid(groupName) ? .new(groupName) : nil
        }
    }

    private func add() {
        guard let groupChoice else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let category = try await plan.addCategory(name: name, to: groupChoice)
                onAdded(category)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension FlagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}
