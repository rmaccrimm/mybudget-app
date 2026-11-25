import SwiftUI

/// Creates an account (SPEC 5.2), with its starting balance.
struct AddAccountSheet: View {
    let plan: PlanModel
    var onAdded: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var balanceText = ""
    @State private var startingDate = Date.now
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Everyday Checking"))
                Picker("Type", selection: $type) {
                    ForEach(AccountGroup.allCases.filter { !$0.types.isEmpty }) { group in
                        Section(group.title) {
                            ForEach(group.types) { type in
                                Label(type.title, systemImage: type.systemImage).tag(type)
                            }
                        }
                    }
                }
            } header: {
                Text("Add Account").font(.headline)
            } footer: {
                Text(typeExplanation)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent(type.isDebt ? "Amount owed" : "Current balance") {
                    AmountField(
                        type.isDebt ? "Amount owed" : "Current balance",
                        text: $balanceText, currencyCode: plan.currencyCode,
                        prompt: Money.formatNumber(0, currencyCode: plan.currencyCode)
                    )
                }
                DatePicker("As of", selection: $startingDate, displayedComponents: .date)
                    .disabled(startingBalance == 0)
            } footer: {
                if startingBalance == nil {
                    Text("Enter an amount, such as \(Money.format(1_234_560, currencyCode: plan.currencyCode)).")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
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
                Button("Add Account", action: add)
                    .disabled(newAccount == nil || saving)
            }
        }
    }

    private var typeExplanation: String {
        switch type.group {
        case .credit:
            "Credit accounts are in your budget. Spending on them comes out of your categories, and the plan sets money aside to pay them."
        case .tracking:
            "Tracking accounts only follow a balance, such as a house or a loan. They don't affect your budget."
        case .cash, .closed:
            "Cash accounts are in your budget: their balance is money you can assign."
        }
    }

    /// The balance in milliunits, signed as the server stores it, or `nil`
    /// if the text isn't an amount.
    private var startingBalance: Int? {
        Money.parse(balanceText, currencyCode: plan.currencyCode).map { type.isDebt ? -$0 : $0 }
    }

    private var newAccount: NewAccount? {
        guard NameRule.isValid(name), let startingBalance else { return nil }
        let note = note.isEmpty ? nil : note
        return NewAccount(
            name: name,
            type: type,
            startingBalance: startingBalance,
            startingDate: startingBalance == 0 ? nil : PlanDate.string(from: startingDate),
            note: note
        )
    }

    private func add() {
        guard let newAccount else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let account = try await plan.addAccount(newAccount)
                dismiss()
                onAdded(account)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Renames an account or changes its note (SPEC 5.7).
struct EditAccountSheet: View {
    let plan: PlanModel
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    @State private var saving = false
    @State private var error: String?

    init(plan: PlanModel, account: Account) {
        self.plan = plan
        self.account = account
        _name = State(initialValue: account.name)
        _note = State(initialValue: account.note ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                LabeledContent("Type", value: account.type.title)
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("Edit Account").font(.headline)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
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
                    .disabled(!NameRule.isValid(name) || saving)
            }
        }
    }

    private var patch: AccountPatch {
        let newNote = note.isEmpty ? nil : note
        return AccountPatch(
            name: name == account.name ? nil : name,
            note: newNote == account.note ? nil : .some(newNote)
        )
    }

    private func save() {
        let patch = patch
        guard patch.name != nil || patch.note != nil else { return dismiss() }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await plan.update(account, patch)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
