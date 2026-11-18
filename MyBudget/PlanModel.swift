import Foundation
import Observation
import os

private let log = Logger(subsystem: "local.mybudget.MyBudget", category: "plan")

/// The open plan and its accounts. Every change goes to the server first, and
/// the local copy is updated from the server's response.
@MainActor
@Observable
final class PlanModel {
    let plan: Plan
    private(set) var accounts: [Account] = []

    @ObservationIgnored private let client: APIClient

    init(plan: Plan, client: APIClient) {
        self.plan = plan
        self.client = client
    }

    var currencyCode: String { plan.currencyCode }

    func account(id: Account.ID) -> Account? {
        accounts.first { $0.id == id }
    }

    func reload() async throws {
        accounts = try await client.accounts(planID: plan.id)
        log.info("Loaded \(self.accounts.count) accounts")
    }

    func addAccount(_ new: NewAccount) async throws -> Account {
        let account = try await client.createAccount(planID: plan.id, new)
        accounts.append(account)
        return account
    }

    func update(_ account: Account, _ patch: AccountPatch) async throws {
        let updated = try await client.updateAccount(
            planID: plan.id, accountID: account.id, patch
        )
        if let index = accounts.firstIndex(where: { $0.id == updated.id }) {
            accounts[index] = updated
        }
    }

    func delete(_ account: Account) async throws {
        try await client.deleteAccount(planID: plan.id, accountID: account.id)
        accounts.removeAll { $0.id == account.id }
    }
}
