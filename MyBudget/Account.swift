import Foundation

/// An account (SPEC section 5). Amounts are milliunits (SPEC 3.7).
struct Account: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let type: AccountType
    let onBudget: Bool
    var closed: Bool
    var note: String?
    var balance: Int
    var clearedBalance: Int
    var unclearedBalance: Int
    let transferPayeeId: String
    let paymentCategoryId: String?

    /// The sidebar group the account is listed under.
    var group: AccountGroup { closed ? .closed : type.group }
}

/// SPEC 5.1. An account's type never changes.
enum AccountType: String, Codable, CaseIterable, Identifiable, Sendable {
    case checking, savings, cash
    case creditCard, lineOfCredit
    case otherAsset, otherLiability

    var id: Self { self }

    var title: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .cash: "Cash"
        case .creditCard: "Credit Card"
        case .lineOfCredit: "Line of Credit"
        case .otherAsset: "Asset"
        case .otherLiability: "Liability"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "building.columns"
        case .savings: "dollarsign.bank.building"
        case .cash: "banknote"
        case .creditCard: "creditcard"
        case .lineOfCredit: "creditcard.and.123"
        case .otherAsset: "chart.line.uptrend.xyaxis"
        case .otherLiability: "chart.line.downtrend.xyaxis"
        }
    }

    /// The group an open account of this type is listed under.
    var group: AccountGroup {
        switch self {
        case .checking, .savings, .cash: .cash
        case .creditCard, .lineOfCredit: .credit
        case .otherAsset, .otherLiability: .tracking
        }
    }

    /// Whether a balance is usually money owed, so the app asks for it as a
    /// positive amount owed and stores it negated.
    var isDebt: Bool {
        switch self {
        case .creditCard, .lineOfCredit, .otherLiability: true
        default: false
        }
    }
}

/// The sidebar's collapsible groups, in the order they're shown.
enum AccountGroup: String, CaseIterable, Identifiable, Sendable {
    case cash, credit, tracking, closed

    var id: Self { self }

    var title: String {
        switch self {
        case .cash: "Cash"
        case .credit: "Credit"
        case .tracking: "Tracking"
        case .closed: "Closed"
        }
    }

    /// The types that belong to an open group, for the type picker.
    var types: [AccountType] {
        AccountType.allCases.filter { $0.group == self }
    }

    /// Accounts are listed in the order given, which is the server's order
    /// (oldest first, SPEC 5.6).
    static func grouped(_ accounts: [Account]) -> [(group: AccountGroup, accounts: [Account])] {
        allCases.compactMap { group in
            let members = accounts.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
    }
}

/// The body of `POST /plans/{plan_id}/accounts` (SPEC 5.2).
struct NewAccount: Encodable, Sendable, Equatable {
    var name: String
    var type: AccountType
    var startingBalance: Int
    /// `YYYY-MM-DD`. Required when `startingBalance` isn't 0, and left out
    /// otherwise.
    var startingDate: String?
    var note: String?
}

/// The body of `PATCH /plans/{plan_id}/accounts/{account_id}` (SPEC 5.7).
/// Only the fields that aren't `nil` are sent.
struct AccountPatch: Encodable, Sendable {
    var name: String?
    /// `.some(nil)` clears the note.
    var note: String??
    var closed: Bool?

    private enum CodingKeys: String, CodingKey { case name, note, closed }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        if let note {
            try container.encode(note, forKey: .note)
        }
        try container.encodeIfPresent(closed, forKey: .closed)
    }
}

/// SPEC 3.9: 1 to 100 Unicode scalars, at least one of them not whitespace.
enum NameRule {
    static let maxLength = 100

    static func isValid(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return (1...maxLength).contains(scalars.count)
            && scalars.contains { !$0.properties.isWhitespace }
    }
}

/// SPEC 3.8 dates, in the user's time zone.
enum PlanDate {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: timeZone).year().month().day()
        )
    }
}
