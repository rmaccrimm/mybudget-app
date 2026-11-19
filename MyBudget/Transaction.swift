import Foundation

/// A transaction (SPEC section 8). Amounts are milliunits (SPEC 3.7), and
/// `date` is `YYYY-MM-DD` (SPEC 3.8).
struct Transaction: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let accountId: Account.ID
    var date: String
    var amount: Int
    var payeeId: Payee.ID?
    var categoryId: Category.ID?
    var memo: String?
    var cleared: ClearedState
    var approved: Bool
    var flagColor: FlagColor?
    /// The other half's account and id, for a transfer (SPEC 9.1).
    var transferAccountId: Account.ID?
    var transferTransactionId: Transaction.ID?
    var subtransactions: [Subtransaction]

    var isTransfer: Bool { transferAccountId != nil }
    var isSplit: Bool { !subtransactions.isEmpty }
}

/// One part of a split (SPEC section 10).
struct Subtransaction: Codable, Hashable, Sendable {
    var amount: Int
    var categoryId: Category.ID
    var memo: String?
}

/// SPEC 8.1.
enum ClearedState: String, Codable, Sendable {
    case uncleared, cleared, reconciled

    /// Cleared and reconciled transactions count towards the cleared balance
    /// (SPEC 5.4).
    var isCleared: Bool { self != .uncleared }

    /// What a new transaction in this account starts as, matching the
    /// server's default (SPEC 8.1): money in a wallet clears at once.
    static func `default`(for type: AccountType) -> ClearedState {
        type == .cash ? .cleared : .uncleared
    }
}

/// SPEC 8.1.
enum FlagColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// A payee (SPEC section 6). A transfer payee stands for an account.
struct Payee: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let transferAccountId: Account.ID?
}

/// A category group and its categories (SPEC 7.1).
struct CategoryGroup: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var hidden: Bool
    /// The internal `Credit Card Payments` group.
    let `internal`: Bool
    var categories: [Category]
}

/// A category (SPEC 7.2).
struct Category: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let groupId: CategoryGroup.ID
    var name: String
    var hidden: Bool
    var note: String?
    /// The credit account this is the payment category of, or `nil` for a
    /// user category. A transaction can never use a payment category.
    let paymentAccountId: Account.ID?

    /// SPEC 7.7: Inflow: Ready to Assign isn't a category object, only an id.
    static let readyToAssign = "ready_to_assign"
}

// MARK: - Requests

/// Who a transaction is with, as SPEC 6.5 lets a request say it.
enum PayeeChoice: Hashable, Sendable {
    case none
    case existing(Payee.ID)
    /// A payee found by name, or created if there's none (SPEC 6.5).
    case named(String)

    /// The payee `text` names. An existing payee's exact name wins, then a
    /// single payee whose name differs only in letter case; anything else is
    /// a new payee. Transfer payees are found by name too, since the app
    /// lists them, except `ownAccount`'s: a transfer to itself isn't allowed
    /// (SPEC 9.2). With `allowTransfers` false, as for a split (SPEC 9.2),
    /// transfer payees aren't matched.
    static func resolve(
        _ text: String, in payees: [Payee], ownAccount: Account.ID?, allowTransfers: Bool = true
    ) -> PayeeChoice {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        let candidates = payees.filter { payee in
            guard let account = payee.transferAccountId else { return true }
            return allowTransfers && account != ownAccount
        }
        // A transfer payee may share an ordinary payee's name (SPEC 6.6);
        // "Transfer : " is only typed on purpose, so the transfer wins.
        let exact = candidates.filter { $0.name == text }
        if let payee = exact.first(where: { $0.transferAccountId != nil }) ?? exact.first {
            return .existing(payee.id)
        }
        let folded = candidates.filter { $0.name.compare(text, options: .caseInsensitive) == .orderedSame }
        if folded.count == 1 {
            return .existing(folded[0].id)
        }
        return .named(text)
    }
}

/// Whether a transaction needs a category (SPEC 8.2 and 9.3).
enum CategoryRule: Equatable, Sendable {
    /// A user category or Ready to Assign is required.
    case required
    /// A transfer between two budget or two tracking accounts.
    case noneForTransfer
    /// A tracking account outside a transfer.
    case noneForTracking

    /// The rule for a transaction in `account`, with `transferTo` the other
    /// account of a transfer.
    static func of(account: Account, transferTo other: Account?) -> CategoryRule {
        if let other {
            // SPEC 9.3: only money entering or leaving the plan has a category.
            return account.onBudget == other.onBudget ? .noneForTransfer : .required
        }
        return account.onBudget ? .required : .noneForTracking
    }
}

/// The body of `POST /plans/{plan_id}/transactions` (SPEC 8.1).
struct NewTransaction: Encodable, Sendable, Equatable {
    var accountId: Account.ID
    var date: String
    var amount: Int
    var payee: PayeeChoice
    /// Left out when `nil`, which the server reads as no category.
    var categoryId: Category.ID?
    var memo: String?
    var cleared: ClearedState
    var flagColor: FlagColor?

    private enum CodingKeys: String, CodingKey {
        case accountId, date, amount, payeeId, payeeName, categoryId, memo, cleared, flagColor
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountId, forKey: .accountId)
        try container.encode(date, forKey: .date)
        try container.encode(amount, forKey: .amount)
        try payee.encode(into: &container, id: .payeeId, name: .payeeName)
        try container.encodeIfPresent(categoryId, forKey: .categoryId)
        try container.encodeIfPresent(memo, forKey: .memo)
        try container.encode(cleared, forKey: .cleared)
        try container.encodeIfPresent(flagColor, forKey: .flagColor)
    }
}

/// The body of `PATCH /plans/{plan_id}/transactions/{transaction_id}` (SPEC
/// 8.6). Only the fields that aren't `nil` are sent; `.some(nil)` sends
/// `null`, which clears a nullable field.
struct TransactionPatch: Encodable, Sendable, Equatable {
    var date: String?
    var amount: Int?
    var payee: PayeeChoice?
    var categoryId: Category.ID??
    var memo: String??
    var cleared: ClearedState?
    var flagColor: FlagColor??

    var isEmpty: Bool { self == TransactionPatch() }

    private enum CodingKeys: String, CodingKey {
        case date, amount, payeeId, payeeName, categoryId, memo, cleared, flagColor
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(amount, forKey: .amount)
        try payee?.encode(into: &container, id: .payeeId, name: .payeeName)
        if let categoryId { try container.encode(categoryId, forKey: .categoryId) }
        if let memo { try container.encode(memo, forKey: .memo) }
        try container.encodeIfPresent(cleared, forKey: .cleared)
        if let flagColor { try container.encode(flagColor, forKey: .flagColor) }
    }
}

private extension PayeeChoice {
    /// SPEC 6.5 and 8.6: `"payee_id": null` with no name removes the payee.
    func encode<Key: CodingKey>(
        into container: inout KeyedEncodingContainer<Key>, id: Key, name: Key
    ) throws {
        switch self {
        case .none: try container.encodeNil(forKey: id)
        case .existing(let payeeID): try container.encode(payeeID, forKey: id)
        case .named(let payeeName): try container.encode(payeeName, forKey: name)
        }
    }
}

// MARK: - The register

/// A row of an account's register: the transaction and, in a single
/// account's register, the account's balance after it.
struct RegisterRow: Identifiable, Hashable, Sendable {
    let transaction: Transaction
    let runningBalance: Int?

    var id: Transaction.ID { transaction.id }

    /// The register for `accountID`, or for every account when it's `nil`,
    /// newest first. `transactions` must be in the server's order: by date,
    /// and oldest first within a date (SPEC 8.5), so the running balance
    /// adds them up in that order.
    static func rows(_ transactions: [Transaction], accountID: Account.ID?) -> [RegisterRow] {
        guard let accountID else {
            return transactions.reversed().map { RegisterRow(transaction: $0, runningBalance: nil) }
        }
        var balance = 0
        var rows: [RegisterRow] = []
        for transaction in transactions where transaction.accountId == accountID {
            balance += transaction.amount
            rows.append(RegisterRow(transaction: transaction, runningBalance: balance))
        }
        return rows.reversed()
    }
}

extension NameRule {
    /// SPEC 3.9: a payee name may have up to 200 characters.
    static let maxPayeeLength = 200
    /// SPEC 3.9: a memo has at most 500 characters.
    static let maxMemoLength = 500
}
