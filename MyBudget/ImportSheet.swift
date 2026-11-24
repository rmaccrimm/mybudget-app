import SwiftUI

/// A file the user picked to import.
struct ImportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Imports an OFX or QFX file (SPEC section 17): previews its statements,
/// lets the user pick an account and options for each, imports them, and
/// says what happened.
struct ImportSheet: View {
    let plan: PlanModel
    let file: ImportFile
    /// The register's account, suggested for a file with one statement the
    /// plan hasn't imported before.
    let suggestedAccountID: Account.ID?

    /// One statement's choices: no account means don't import it.
    private struct Choice {
        var accountID: Account.ID?
        var swapPayeeMemo: Bool
        var invertAmounts: Bool

        var options: StatementOptions? {
            accountID.map {
                StatementOptions(accountId: $0, swapPayeeMemo: swapPayeeMemo, invertAmounts: invertAmounts)
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var preview: ImportPreview?
    @State private var choices: [Choice] = []
    @State private var result: ImportResult?
    @State private var loadError: String?
    @State private var importError: String?
    @State private var importing = false

    private var fileName: String { file.url.lastPathComponent }

    var body: some View {
        Group {
            if let preview, let result {
                results(preview, result)
            } else if let preview {
                form(preview)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Read \(fileName)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
                .padding()
            } else {
                ProgressView("Reading \(fileName)…").padding(40)
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task { await load() }
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if result != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if preview != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: runImport)
                        .disabled(importing || choices.allSatisfy { $0.accountID == nil })
                }
            }
        }
    }

    // MARK: Choosing

    private func form(_ preview: ImportPreview) -> some View {
        Form {
            ForEach(Array(preview.statements.enumerated()), id: \.offset) { index, statement in
                Section {
                    statementChoices(statement, $choices[index])
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        if index == 0 {
                            Text("Import \(fileName)").font(.headline).padding(.bottom, 6)
                        }
                        Text(Self.title(statement)).font(.subheadline.weight(.semibold))
                        Text(details(statement)).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    if let currency = statement.currencyCode,
                       currency.caseInsensitiveCompare(plan.currencyCode) != .orderedSame {
                        Text("This statement is in \(currency), but the plan uses \(plan.currencyCode). Amounts are imported as they are, without converting them.")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let importError {
                Section {
                    Text(importError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(importing)
    }

    @ViewBuilder
    private func statementChoices(_ statement: StatementPreview, _ choice: Binding<Choice>) -> some View {
        Picker("Import into", selection: choice.accountID) {
            Text("Don't Import").tag(Account.ID?.none)
            ForEach(AccountGroup.grouped(plan.accounts), id: \.group) { group, accounts in
                Section(group.title) {
                    ForEach(accounts) { account in
                        Label(account.name, systemImage: account.type.systemImage)
                            .tag(Account.ID?.some(account.id))
                    }
                }
            }
        }
        if choice.wrappedValue.accountID != nil {
            Toggle(isOn: choice.swapPayeeMemo) {
                Text("Swap payee and memo")
                Text("For banks that put the merchant in the memo.")
            }
            Toggle(isOn: choice.invertAmounts) {
                Text("Reverse inflows and outflows")
                Text("For banks that write spending as a positive amount.")
            }
            if !statement.transactions.isEmpty {
                DisclosureGroup(Self.count(statement.transactions.count)) {
                    transactionList(statement.transactions, choice.wrappedValue)
                }
            }
        }
    }

    private func transactionList(_ transactions: [BankTransaction], _ choice: Choice) -> some View {
        let options = choice.options ?? StatementOptions(accountId: "")
        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(transactions, id: \.importId) { transaction in
                    let shown = transaction.applying(options)
                    HStack(alignment: .firstTextBaseline) {
                        Text(PlanDate.display(transaction.date))
                            .monospacedDigit()
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(shown.payee ?? "No payee")
                                .foregroundStyle(shown.payee == nil ? .secondary : .primary)
                            if let memo = shown.memo {
                                Text(memo).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer()
                        Text(Money.format(shown.amount, currencyCode: plan.currencyCode))
                            .monospacedDigit()
                            .foregroundStyle(shown.amount < 0 ? Color.primary : Color.green)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 220)
    }

    // MARK: Results

    private func results(_ preview: ImportPreview, _ result: ImportResult) -> some View {
        Form {
            ForEach(Array(zip(preview.statements, result.statements).enumerated()), id: \.offset) { index, pair in
                let (statement, outcome) = pair
                Section {
                    if let outcome {
                        LabeledContent("Added", value: "\(outcome.imported.count)")
                        LabeledContent("Matched to transactions you entered", value: "\(outcome.matched.count)")
                        LabeledContent("Already imported, skipped", value: "\(outcome.duplicates.count)")
                        if let ledger = statement.ledgerBalance,
                           let account = plan.account(id: outcome.accountId) {
                            let bank = choices[index].invertAmounts ? -ledger : ledger
                            LabeledContent(
                                statement.ledgerBalanceDate.map { "Bank's balance on \(PlanDate.display($0))" }
                                    ?? "Bank's balance",
                                value: Money.format(bank, currencyCode: plan.currencyCode)
                            )
                            LabeledContent(
                                "\(account.name)'s cleared balance",
                                value: Money.format(account.clearedBalance, currencyCode: plan.currencyCode)
                            )
                        }
                    } else {
                        Text("Not imported").foregroundStyle(.secondary)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        if index == 0 {
                            Text("Imported \(fileName)").font(.headline).padding(.bottom, 6)
                        }
                        Text(header(statement, outcome)).font(.subheadline.weight(.semibold))
                    }
                } footer: {
                    if let outcome, !outcome.matched.isEmpty {
                        Text("Matched transactions keep what you entered and are now cleared.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func header(_ statement: StatementPreview, _ outcome: StatementResult?) -> String {
        guard let account = outcome.flatMap({ plan.account(id: $0.accountId) }) else {
            return Self.title(statement)
        }
        return "\(Self.title(statement)) → \(account.name)"
    }

    // MARK: Text

    /// Such as "Checking ••••6789" or "Credit Card ••••1234".
    static func title(_ statement: StatementPreview) -> String {
        let kind = switch statement.type {
        case .creditCard: "Credit Card"
        case .bank: statement.accountType.map { $0.capitalized } ?? "Bank Account"
        }
        return [kind, statement.maskedAccountNumber].compactMap(\.self).joined(separator: " ")
    }

    private func details(_ statement: StatementPreview) -> String {
        var parts: [String] = []
        switch (statement.startDate, statement.endDate) {
        case let (start?, end?): parts.append("\(PlanDate.display(start)) – \(PlanDate.display(end))")
        case let (start?, nil): parts.append("From \(PlanDate.display(start))")
        case let (nil, end?): parts.append("To \(PlanDate.display(end))")
        case (nil, nil): break
        }
        parts.append(Self.count(statement.transactions.count))
        return parts.joined(separator: " · ")
    }

    static func count(_ n: Int) -> String {
        n == 1 ? "1 transaction" : "\(n) transactions"
    }

    // MARK: Actions

    private func load() async {
        guard data == nil else { return }
        do {
            let accessing = file.url.startAccessingSecurityScopedResource()
            defer { if accessing { file.url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: file.url)
            let preview = try await plan.previewImport(data)
            self.data = data
            choices = preview.statements.map { statement in
                let remembered = statement.accountId.flatMap(plan.account(id:))?.id
                let suggested = preview.statements.count == 1 ? suggestedAccountID : nil
                return Choice(
                    accountID: remembered ?? suggested,
                    swapPayeeMemo: statement.swapPayeeMemo,
                    invertAmounts: statement.invertAmounts
                )
            }
            self.preview = preview
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func runImport() {
        guard let data else { return }
        importing = true
        importError = nil
        Task {
            defer { importing = false }
            do {
                result = try await plan.importFile(data, statements: choices.map(\.options))
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
