import Foundation
import Testing
@testable import MyBudget

struct TransactionRuleTests {
    @Test func decodesTheServersTransaction() throws {
        // SPEC 10.1's example response.
        let json = """
        {"id": "SPLIT_ID", "account_id": "CHECKING_ID", "date": "2026-10-06", "amount": -90000,
         "payee_id": "MEGASTORE_ID", "category_id": null, "memo": null,
         "cleared": "uncleared", "approved": true, "flag_color": null,
         "transfer_account_id": null, "transfer_transaction_id": null,
         "subtransactions": [{"amount": -60000, "category_id": "GROCERIES_ID", "memo": null},
                             {"amount": -30000, "category_id": "HOUSEHOLD_ID", "memo": "light bulbs"}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let transaction = try decoder.decode(Transaction.self, from: Data(json.utf8))
        #expect(transaction.accountId == "CHECKING_ID")
        #expect(transaction.cleared == .uncleared)
        #expect(transaction.isSplit)
        #expect(!transaction.isTransfer)
        #expect(transaction.subtransactions[1].memo == "light bulbs")
    }

    @Test func runningBalanceAddsUpOldestFirstAndListsNewestFirst() {
        let transactions = [
            Self.transaction("a", account: "checking", amount: 2_500_000),
            Self.transaction("b", account: "savings", amount: 100_000),
            Self.transaction("c", account: "checking", amount: -120_000),
            Self.transaction("d", account: "checking", amount: -30_000),
        ]
        let rows = RegisterRow.rows(transactions, accountID: "checking")
        #expect(rows.map(\.id) == ["d", "c", "a"])
        #expect(rows.map(\.runningBalance) == [2_350_000, 2_380_000, 2_500_000])

        let all = RegisterRow.rows(transactions, accountID: nil)
        #expect(all.map(\.id) == ["d", "c", "b", "a"])
        #expect(all.allSatisfy { $0.runningBalance == nil })
    }

    @Test func resolvesPayeeNames() {
        let payees = [
            Payee(id: "shop", name: "Corner Shop", transferAccountId: nil),
            Payee(id: "to-checking", name: "Transfer : Checking", transferAccountId: "checking"),
            Payee(id: "to-savings", name: "Transfer : Savings", transferAccountId: "savings"),
            Payee(id: "fake", name: "Transfer : Savings", transferAccountId: nil),
        ]
        func resolve(_ text: String, allowTransfers: Bool = true) -> PayeeChoice {
            .resolve(text, in: payees, ownAccount: "checking", allowTransfers: allowTransfers)
        }
        #expect(resolve("") == .none)
        #expect(resolve("  ") == .none)
        #expect(resolve("Corner Shop") == .existing("shop"))
        #expect(resolve("corner shop ") == .existing("shop"))
        #expect(resolve("Bakery") == .named("Bakery"))
        // SPEC 6.6: a transfer payee may share an ordinary payee's name.
        #expect(resolve("Transfer : Savings") == .existing("to-savings"))
        #expect(resolve("Transfer : Savings", allowTransfers: false) == .existing("fake"))
        // SPEC 9.2: no transfer from an account to itself.
        #expect(resolve("Transfer : Checking") == .named("Transfer : Checking"))
    }

    @Test func categoriesFollowTheAccounts() {
        let checking = AccountRuleTests.account("checking", .checking)
        let visa = AccountRuleTests.account("visa", .creditCard)
        let house = AccountRuleTests.account("house", .otherAsset)
        let loan = AccountRuleTests.account("loan", .otherLiability)
        #expect(CategoryRule.of(account: checking, transferTo: nil) == .required)
        #expect(CategoryRule.of(account: house, transferTo: nil) == .noneForTracking)
        // SPEC 9.3.
        #expect(CategoryRule.of(account: checking, transferTo: visa) == .noneForTransfer)
        #expect(CategoryRule.of(account: house, transferTo: loan) == .noneForTransfer)
        #expect(CategoryRule.of(account: checking, transferTo: house) == .required)
        #expect(CategoryRule.of(account: house, transferTo: checking) == .required)
    }

    @Test func newTransactionSendsAPayeeByIdOrName() throws {
        var new = NewTransaction(
            accountId: "checking", date: "2026-10-04", amount: -120_000,
            payee: .named("Corner Shop"), categoryId: "groceries", memo: nil,
            cleared: .uncleared, flagColor: nil
        )
        var body = try Self.json(new)
        #expect(body.keys.sorted() == ["account_id", "amount", "category_id", "cleared", "date", "payee_name"])
        #expect(body["payee_name"] as? String == "Corner Shop")

        new.payee = .existing("shop")
        new.categoryId = nil
        body = try Self.json(new)
        #expect(body["payee_id"] as? String == "shop")
        #expect(body["category_id"] == nil)
    }

    @Test func patchSendsOnlyWhatChanged() throws {
        #expect(try Self.json(TransactionPatch(cleared: .cleared)).keys.sorted() == ["cleared"])
        #expect(TransactionPatch().isEmpty)

        let cleared = try Self.json(TransactionPatch(payee: PayeeChoice.none, memo: .some(nil), flagColor: .some(nil)))
        #expect(cleared.keys.sorted() == ["flag_color", "memo", "payee_id"])
        #expect(cleared.values.allSatisfy { $0 is NSNull })

        let renamed = try Self.json(TransactionPatch(payee: .named("Bakery"), categoryId: .some("bread")))
        #expect(renamed.keys.sorted() == ["category_id", "payee_name"])
    }

    @Test func readsAndShowsPlanDates() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let date = try #require(PlanDate.date(from: "2026-10-04", timeZone: losAngeles))
        #expect(PlanDate.string(from: date, timeZone: losAngeles) == "2026-10-04")
        #expect(PlanDate.date(from: "2026-13-01") == nil)
        #expect(PlanDate.display("2026-10-04", timeZone: losAngeles, locale: Locale(identifier: "en_US")) == "10/4/2026")
    }

    static func transaction(_ id: String, account: String, amount: Int, date: String = "2026-10-01") -> Transaction {
        Transaction(
            id: id, accountId: account, date: date, amount: amount, payeeId: nil, categoryId: nil,
            memo: nil, cleared: .uncleared, approved: true, flagColor: nil,
            transferAccountId: nil, transferTransactionId: nil, subtransactions: []
        )
    }

    static func json(_ body: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: APIClient.encoder.encode(body)) as! [String: Any]
    }
}

/// `PlanModel` against the bundled server, kept in memory.
@MainActor
@Suite(.serialized)
struct BundledTransactionTests {
    @Test func addsEditsAndDeletesTransactions() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        let plan = PlanModel(plan: try await client.createPlan(name: "Household"), client: client)
        try await plan.reload()

        let checking = try await plan.addAccount(NewAccount(
            name: "Checking", type: .checking, startingBalance: 1_000_000, startingDate: "2026-10-01"
        ))
        let groceries = try await plan.addCategory(name: "Groceries", to: .new("Everyday"))
        #expect(plan.userCategoryGroups.map(\.name) == ["Everyday"])

        let shop = try await plan.addTransaction(NewTransaction(
            accountId: checking.id, date: "2026-10-04", amount: -120_000,
            payee: .named("Corner Shop"), categoryId: groceries.id, memo: "weekly shop",
            cleared: .uncleared, flagColor: nil
        ))
        // The payee was created by name (SPEC 6.5), and the balance moved.
        #expect(plan.payeeName(shop.payeeId) == "Corner Shop")
        #expect(plan.account(id: checking.id)?.balance == 880_000)
        #expect(plan.account(id: checking.id)?.unclearedBalance == -120_000)
        let rows = RegisterRow.rows(plan.transactions, accountID: checking.id)
        #expect(rows.map(\.runningBalance) == [880_000, 1_000_000])
        #expect(plan.lastCategory(forPayee: try #require(shop.payeeId)) == groceries.id)

        try await plan.update(shop, TransactionPatch(cleared: .cleared, flagColor: .some(.green)))
        let edited = try #require(plan.transaction(id: shop.id))
        #expect(edited.cleared == .cleared)
        #expect(edited.flagColor == .green)
        #expect(edited.memo == "weekly shop")
        #expect(plan.account(id: checking.id)?.clearedBalance == 880_000)

        try await plan.delete([edited])
        #expect(plan.transaction(id: shop.id) == nil)
        #expect(plan.account(id: checking.id)?.balance == 1_000_000)
    }

    @Test func transfersShowInBothAccounts() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        let plan = PlanModel(plan: try await client.createPlan(name: "Household"), client: client)
        try await plan.reload()

        let checking = try await plan.addAccount(NewAccount(name: "Checking", type: .checking, startingBalance: 0))
        let savings = try await plan.addAccount(NewAccount(name: "Savings", type: .savings, startingBalance: 0))
        let toSavings = PayeeChoice.resolve("Transfer : Savings", in: plan.payees, ownAccount: checking.id)
        #expect(toSavings == .existing(savings.transferPayeeId))

        let out = try await plan.addTransaction(NewTransaction(
            accountId: checking.id, date: "2026-10-05", amount: -500_000, payee: toSavings,
            categoryId: nil, memo: nil, cleared: .uncleared, flagColor: nil
        ))
        let otherHalf = try #require(out.transferTransactionId.flatMap(plan.transaction(id:)))
        #expect(otherHalf.accountId == savings.id)
        #expect(otherHalf.amount == 500_000)
        #expect(plan.account(id: savings.id)?.balance == 500_000)

        // SPEC 9.4: a new amount on one half moves the other.
        try await plan.update(out, TransactionPatch(amount: -400_000))
        #expect(plan.transaction(id: otherHalf.id)?.amount == 400_000)

        // SPEC 9.6: deleting one half deletes both, and asking for both is fine.
        try await plan.delete([out, otherHalf])
        #expect(plan.transactions.isEmpty)
    }
}
