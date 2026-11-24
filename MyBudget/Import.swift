import Foundation
import UniformTypeIdentifiers

/// What `POST /plans/{plan_id}/imports/preview` finds in a file (SPEC 17.6).
struct ImportPreview: Decodable, Sendable {
    let statements: [StatementPreview]
}

/// One statement in an OFX file (SPEC 17.6).
struct StatementPreview: Decodable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case bank
        case creditCard = "credit_card"
    }

    let type: Kind
    let bankId: String?
    let accountNumber: String?
    let accountType: String?
    let currencyCode: String?
    let startDate: String?
    let endDate: String?
    let ledgerBalance: Int?
    let ledgerBalanceDate: String?
    /// What the last import of this statement's account used (SPEC 17.13).
    let accountId: Account.ID?
    let swapPayeeMemo: Bool
    let invertAmounts: Bool
    let transactions: [BankTransaction]

    /// The account number as a statement shows it: the last four digits.
    var maskedAccountNumber: String? {
        guard let accountNumber else { return nil }
        return accountNumber.count > 4 ? "••••" + accountNumber.suffix(4) : accountNumber
    }
}

/// A bank transaction as the file has it, before any options (SPEC 17.6).
struct BankTransaction: Decodable, Hashable, Sendable {
    let importId: String
    let type: String?
    let date: String
    let amount: Int
    let name: String?
    let memo: String?

    /// The payee, memo and amount the import will use (SPEC 17.8).
    func applying(_ options: StatementOptions) -> (payee: String?, memo: String?, amount: Int) {
        (
            options.swapPayeeMemo ? memo : name,
            options.swapPayeeMemo ? name : memo,
            options.invertAmounts ? -amount : amount
        )
    }
}

/// One entry of `statements` in `POST /plans/{plan_id}/imports` (SPEC
/// 17.7). A statement that isn't imported is sent as `null`.
struct StatementOptions: Encodable, Hashable, Sendable {
    var accountId: Account.ID
    var swapPayeeMemo = false
    var invertAmounts = false
}

/// What `POST /plans/{plan_id}/imports` did (SPEC 17.7): one entry per
/// statement, `nil` for one that was skipped.
struct ImportResult: Decodable, Sendable {
    let statements: [StatementResult?]
}

struct StatementResult: Decodable, Hashable, Sendable {
    let accountId: Account.ID
    let imported: [Transaction]
    let matched: [Transaction]
    let duplicates: [DuplicateTransaction]
}

/// A bank transaction skipped because the account already has it (SPEC 17.9).
struct DuplicateTransaction: Decodable, Hashable, Sendable {
    let id: String
    let date: String
    let amount: Int
    let payeeName: String?
    let memo: String?
    let transactionId: Transaction.ID?
}

extension UTType {
    /// OFX statements, and QFX, Quicken's flavor of them (SPEC section 17).
    /// Few Macs declare these types, so they're looked up by extension.
    static let bankStatements: [UTType] = ["ofx", "qfx"].compactMap { UTType(filenameExtension: $0) }
}
