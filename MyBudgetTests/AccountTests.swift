import Foundation
import Testing
@testable import MyBudget

struct MoneyTests {
    private let us = Locale(identifier: "en_US")

    @Test(arguments: [
        ("", 0),
        ("0", 0),
        ("2500", 2_500_000),
        ("2,500.00", 2_500_000),
        ("$2,500.00", 2_500_000),
        ("12.34", 12_340),
        ("-0.22", -220),
        ("-$0.22", -220),
        ("USD 3", 3_000),
        ("  7  ", 7_000),
        ("1000000000", 1_000_000_000_000),
        // Rounded half away from zero to the cent, as the amount is shown.
        ("0.004", 0),
        ("0.005", 10),
        ("1.0001", 1_000),
        ("-1.005", -1_010),
        ("1000000000.004", 1_000_000_000_000),
    ])
    func parsesAmounts(text: String, milliunits: Int) {
        #expect(Money.parse(text, currencyCode: "USD", locale: us) == milliunits)
    }

    @Test(arguments: ["abc", "$", "12abc", "1.2.3", "1,,2", "1000000000.01", "-1000000001"])
    func rejectsWhatIsntAnAmount(text: String) {
        #expect(Money.parse(text, currencyCode: "USD", locale: us) == nil)
    }

    @Test func readsTheLocalesDecimalSeparator() {
        let germany = Locale(identifier: "de_DE")
        #expect(Money.parse("1.234,56", currencyCode: "EUR", locale: germany) == 1_234_560)
    }

    @Test func formatsInThePlansCurrency() {
        #expect(Money.format(2_500_000, currencyCode: "USD", locale: us) == "$2,500.00")
        #expect(Money.format(-350_000, currencyCode: "USD", locale: us) == "-$350.00")
        let canada = Locale(identifier: "en_CA")
        #expect(Money.format(0, currencyCode: "USD", locale: canada) == "US$0.00")
        #expect(Money.format(0, currencyCode: "USD", locale: canada, narrow: true) == "$0.00")
        #expect(Money.formatNumber(-1_234_500, currencyCode: "USD", locale: canada) == "-1,234.50")
        #expect(Money.symbol(currencyCode: "USD", locale: canada) == ("$", true))
        #expect(Money.parse("$12.50", currencyCode: "USD", locale: canada) == 12_500)
        let germany = Locale(identifier: "de_DE")
        #expect(Money.symbol(currencyCode: "EUR", locale: germany) == ("€", false))
        #expect(Money.formatNumber(1_234_500, currencyCode: "EUR", locale: germany) == "1.234,50")
        // Arabic formats mark the number's direction; the symbol has no marks.
        let egypt = Locale(identifier: "ar_EG")
        #expect(Money.symbol(currencyCode: "EGP", locale: egypt) == ("E£", false))
    }
}

struct AccountRuleTests {
    @Test func groupsAccountsInSidebarOrderAndKeepsServerOrder() {
        let accounts = [
            Self.account("visa", .creditCard),
            Self.account("checking", .checking),
            Self.account("old", .savings, closed: true),
            Self.account("cash", .cash),
            Self.account("house", .otherAsset),
        ]
        let grouped = AccountGroup.grouped(accounts)
        #expect(grouped.map(\.group) == [.cash, .credit, .tracking, .closed])
        #expect(grouped[0].accounts.map(\.id) == ["checking", "cash"])
        #expect(grouped[3].accounts.map(\.id) == ["old"])
    }

    @Test func leavesOutEmptyGroups() {
        let grouped = AccountGroup.grouped([Self.account("visa", .lineOfCredit)])
        #expect(grouped.map(\.group) == [.credit])
    }

    @Test(arguments: [
        ("Checking", true),
        ("", false),
        (" \t", false),
        (String(repeating: "a", count: 100), true),
        (String(repeating: "a", count: 101), false),
    ])
    func checksNames(name: String, valid: Bool) {
        #expect(NameRule.isValid(name) == valid)
    }

    @Test func writesDatesInTheGivenTimeZone() throws {
        // 2026-10-01 at 23:30 in Los Angeles is already October 2nd in UTC.
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 30)))
        #expect(PlanDate.string(from: date, timeZone: losAngeles) == "2026-10-01")
    }

    @Test func patchSendsOnlyItsFieldsAndNullToClearANote() throws {
        func json(_ patch: AccountPatch) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as! [String: Any]
        }
        #expect(try json(AccountPatch(closed: true)).keys.sorted() == ["closed"])
        let cleared = try json(AccountPatch(note: .some(nil)))
        #expect(cleared.keys.sorted() == ["note"])
        #expect(cleared["note"] is NSNull)
    }

    static func account(_ id: String, _ type: AccountType, closed: Bool = false) -> Account {
        Account(
            id: id, name: id, type: type, onBudget: type.group != .tracking, closed: closed,
            note: nil, balance: 0, clearedBalance: 0, unclearedBalance: 0,
            transferPayeeId: "\(id)-payee", paymentCategoryId: nil
        )
    }
}

/// These run against the bundled server, like `BundledServerTests`.
@MainActor
@Suite(.serialized)
struct BundledAccountTests {
    @Test func createsAccountsWithStartingBalances() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        let plan = try await client.createPlan(name: "Household", currencyCode: "EUR")
        #expect(plan.currencyCode == "EUR")

        let checking = try await client.createAccount(planID: plan.id, NewAccount(
            name: "Checking", type: .checking, startingBalance: 2_500_000,
            startingDate: "2026-10-01", note: "Joint"
        ))
        #expect(checking.balance == 2_500_000)
        #expect(checking.onBudget)
        #expect(checking.note == "Joint")
        #expect(checking.paymentCategoryId == nil)

        let visa = try await client.createAccount(planID: plan.id, NewAccount(
            name: "Visa", type: .creditCard, startingBalance: 0
        ))
        #expect(visa.balance == 0)
        #expect(visa.paymentCategoryId != nil)

        #expect(try await client.accounts(planID: plan.id) == [checking, visa])
    }

    @Test func closesReopensRenamesAndDeletes() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        let plan = try await client.createPlan(name: "Household")
        let model = PlanModel(plan: plan, client: client)

        let savings = try await model.addAccount(NewAccount(name: "Savings", type: .savings, startingBalance: 0))
        try await model.update(savings, AccountPatch(closed: true))
        #expect(model.accounts.map(\.group) == [.closed])

        try await model.update(savings, AccountPatch(name: "Rainy Day", note: .some("Emergencies"), closed: false))
        #expect(model.accounts.first?.name == "Rainy Day")
        #expect(model.accounts.first?.note == "Emergencies")
        #expect(model.accounts.first?.group == .cash)

        try await model.update(savings, AccountPatch(note: .some(nil)))
        #expect(model.accounts.first?.note == nil)

        try await model.delete(savings)
        #expect(model.accounts.isEmpty)
        try await model.reload()
        #expect(model.accounts.isEmpty)
    }

    @Test func refusesToCloseOrDeleteAnAccountWithMoneyInIt() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        let plan = try await client.createPlan(name: "Household")
        let model = PlanModel(plan: plan, client: client)
        let cash = try await model.addAccount(NewAccount(
            name: "Wallet", type: .cash, startingBalance: 40_000, startingDate: "2026-11-01"
        ))

        // SPEC 5.8 and 5.9.
        let closeError = try await #require(throws: APIClient.ServerError.self) {
            try await model.update(cash, AccountPatch(closed: true))
        }
        #expect(closeError.status == 409)
        let deleteError = try await #require(throws: APIClient.ServerError.self) {
            try await model.delete(cash)
        }
        #expect(deleteError.status == 409)
        #expect(model.accounts == [cash])
    }
}
