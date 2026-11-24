import Foundation
import Observation
import os

private let log = Logger(subsystem: "local.mybudget.MyBudget", category: "plan")

/// The open plan: its accounts, transactions, payees and categories. Every
/// change goes to the server first. A change often reaches further than the
/// object it's made on: a transfer edits its other half (SPEC 9.4), a payee
/// name creates a payee (SPEC 6.5), and renaming an account renames its
/// transfer payee (SPEC 5.7). So after each change the model reloads what it
/// might have touched, rather than patching its copy.
@MainActor
@Observable
final class PlanModel {
    let plan: Plan
    private(set) var accounts: [Account] = []
    /// In the server's order: by date, oldest first within a date (SPEC 8.5).
    private(set) var transactions: [Transaction] = []
    private(set) var payees: [Payee] = [] {
        didSet { payeesByID = Dictionary(uniqueKeysWithValues: payees.map { ($0.id, $0) }) }
    }
    private(set) var categoryGroups: [CategoryGroup] = [] {
        didSet {
            categoriesByID = Dictionary(
                uniqueKeysWithValues: categoryGroups.flatMap(\.categories).map { ($0.id, $0) }
            )
        }
    }

    /// The month the Plan page shows, and its budget once loaded.
    var selectedMonth = BudgetMonth.current()
    private(set) var month: MonthBudget?

    @ObservationIgnored private(set) var payeesByID: [Payee.ID: Payee] = [:]
    @ObservationIgnored private(set) var categoriesByID: [Category.ID: Category] = [:]
    @ObservationIgnored private let client: APIClient

    init(plan: Plan, client: APIClient) {
        self.plan = plan
        self.client = client
    }

    var currencyCode: String { plan.currencyCode }

    func account(id: Account.ID) -> Account? {
        accounts.first { $0.id == id }
    }

    func transaction(id: Transaction.ID) -> Transaction? {
        transactions.first { $0.id == id }
    }

    /// The groups a transaction's category can come from: every group but
    /// the internal one, whose payment categories are never allowed (SPEC
    /// 8.2).
    var userCategoryGroups: [CategoryGroup] {
        categoryGroups.filter { !$0.internal }
    }

    func reload() async throws {
        let (id, client) = (plan.id, client)
        async let accounts = client.accounts(planID: id)
        async let transactions = client.transactions(planID: id)
        async let payees = client.payees(planID: id)
        async let categoryGroups = client.categoryGroups(planID: id)
        (self.accounts, self.transactions, self.payees, self.categoryGroups) =
            try await (accounts, transactions, payees, categoryGroups)
        log.info("Loaded \(self.accounts.count) accounts and \(self.transactions.count) transactions")
    }

    // MARK: Accounts

    /// Creating an account also creates its transfer payee, its starting
    /// balance and, for a credit account, its payment category (SPEC 5.5).
    func addAccount(_ new: NewAccount) async throws -> Account {
        let account = try await client.createAccount(planID: plan.id, new)
        try await reload()
        return account
    }

    func update(_ account: Account, _ patch: AccountPatch) async throws {
        _ = try await client.updateAccount(planID: plan.id, accountID: account.id, patch)
        try await reload()
    }

    func delete(_ account: Account) async throws {
        try await client.deleteAccount(planID: plan.id, accountID: account.id)
        try await reload()
    }

    // MARK: Transactions

    func addTransaction(_ new: NewTransaction) async throws -> Transaction {
        let transaction = try await client.createTransaction(planID: plan.id, new)
        try await reloadAfterTransactionChange()
        return transaction
    }

    func update(_ transaction: Transaction, _ patch: TransactionPatch) async throws {
        guard !patch.isEmpty else { return }
        _ = try await client.updateTransaction(
            planID: plan.id, transactionID: transaction.id, patch
        )
        try await reloadAfterTransactionChange()
    }

    /// Applies `patch` to each transaction in turn, stopping at the first
    /// failure, then reloads once.
    func update(_ transactions: [Transaction], _ patch: (Transaction) -> TransactionPatch?) async throws {
        try await eachThenReload(transactions) { transaction in
            guard let patch = patch(transaction), !patch.isEmpty else { return }
            _ = try await self.client.updateTransaction(
                planID: self.plan.id, transactionID: transaction.id, patch
            )
        }
    }

    /// Deletes each transaction, skipping the other half of a transfer
    /// already deleted with its first (SPEC 9.6).
    func delete(_ transactions: [Transaction]) async throws {
        var deleted = Set<Transaction.ID>()
        try await eachThenReload(transactions) { transaction in
            guard !deleted.contains(transaction.id) else { return }
            try await self.client.deleteTransaction(planID: self.plan.id, transactionID: transaction.id)
            deleted.insert(transaction.id)
            if let other = transaction.transferTransactionId {
                deleted.insert(other)
            }
        }
    }

    /// Runs `change` on each transaction in turn, then reloads, even when a
    /// change fails partway, so the register shows what did change.
    private func eachThenReload(
        _ transactions: [Transaction], _ change: (Transaction) async throws -> Void
    ) async throws {
        do {
            for transaction in transactions {
                try await change(transaction)
            }
        } catch {
            try? await reloadAfterTransactionChange()
            throw error
        }
        try await reloadAfterTransactionChange()
    }

    // MARK: Imports

    func previewImport(_ file: Data) async throws -> ImportPreview {
        try await client.previewImport(planID: plan.id, file: file)
    }

    /// Imports a file's statements (SPEC 17.7), creating transactions and
    /// payees and clearing the ones it matches.
    func importFile(_ file: Data, statements: [StatementOptions?]) async throws -> ImportResult {
        let result = try await client.importFile(planID: plan.id, file: file, statements: statements)
        try await reloadAfterTransactionChange()
        return result
    }

    /// Balances, transactions and payees can all change with a transaction.
    private func reloadAfterTransactionChange() async throws {
        let (id, client) = (plan.id, client)
        async let accounts = client.accounts(planID: id)
        async let transactions = client.transactions(planID: id)
        async let payees = client.payees(planID: id)
        (self.accounts, self.transactions, self.payees) = try await (accounts, transactions, payees)
    }

    // MARK: Categories

    /// Creates a category at the end of a group, creating the group first
    /// when `group` names a new one.
    func addCategory(name: String, to group: CategoryGroupChoice) async throws -> Category {
        let groupID: CategoryGroup.ID
        switch group {
        case .existing(let id):
            groupID = id
        case .new(let groupName):
            groupID = try await client.createCategoryGroup(planID: plan.id, name: groupName).id
        }
        let category = try await client.createCategory(planID: plan.id, groupID: groupID, name: name)
        categoryGroups = try await client.categoryGroups(planID: plan.id)
        return category
    }

    // MARK: Budget

    /// Loads `selectedMonth`. A response for a month no longer selected is
    /// dropped.
    func loadMonth() async throws {
        let requested = selectedMonth
        let loaded = try await client.month(planID: plan.id, month: requested)
        if requested == selectedMonth { month = loaded }
    }

    func setAssigned(_ assigned: Int, categoryID: Category.ID) async throws {
        _ = try await client.setAssigned(
            planID: plan.id, month: selectedMonth, categoryID: categoryID, assigned: assigned
        )
        try await reloadAfterBudgetChange()
    }

    /// Sets or, with `nil`, removes a category's target (SPEC 18.4).
    func setTarget(_ target: TargetInput?, categoryID: Category.ID) async throws {
        _ = try await client.setTarget(planID: plan.id, categoryID: categoryID, target)
        try await reloadAfterBudgetChange()
    }

    /// Assigning or a target changes later months and the header, and targets
    /// are in the category list.
    private func reloadAfterBudgetChange() async throws {
        categoryGroups = try await client.categoryGroups(planID: plan.id)
        try await loadMonth()
    }

    // MARK: Names

    func payeeName(_ id: Payee.ID?) -> String {
        id.flatMap { payeesByID[$0]?.name } ?? ""
    }

    func categoryName(_ id: Category.ID?) -> String {
        guard let id else { return "" }
        if id == Category.readyToAssign { return "Ready to Assign" }
        return categoriesByID[id]?.name ?? ""
    }

    /// The category the payee's latest transaction used, to suggest for a new
    /// one, as YNAB does.
    func lastCategory(forPayee id: Payee.ID) -> Category.ID? {
        transactions.last { $0.payeeId == id && $0.categoryId != nil }?.categoryId
    }
}

/// The group a new category goes in.
enum CategoryGroupChoice: Hashable, Sendable {
    case existing(CategoryGroup.ID)
    case new(String)
}
