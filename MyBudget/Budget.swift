import Foundation

/// A calendar month, written `YYYY-MM` on the wire (SPEC 3.8).
struct BudgetMonth: Hashable, Comparable, Sendable, Identifiable {
    var year: Int
    var month: Int

    var id: String { key }

    /// `YYYY-MM`, which also sorts in calendar order.
    var key: String { String(format: "%04d-%02d", year, month) }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month)
        else { return nil }
        self.init(year: year, month: month)
    }

    /// The month `date` falls in, by the local clock.
    init(containing date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    static func current(now: Date = .now, calendar: Calendar = .current) -> BudgetMonth {
        BudgetMonth(containing: now, calendar: calendar)
    }

    func adding(months: Int) -> BudgetMonth {
        let index = year * 12 + (month - 1) + months
        return BudgetMonth(year: index.floorDiv(12), month: index.floorMod(12) + 1)
    }

    static func < (lhs: BudgetMonth, rhs: BudgetMonth) -> Bool { lhs.key < rhs.key }

    /// "November 2026".
    var title: String {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = 1
        guard let date = Calendar(identifier: .gregorian).date(from: parts) else { return key }
        return date.formatted(.dateTime.month(.wide).year().locale(.current))
    }

    /// The months the Plan page can show (the user's rule): from `1900-01`, the
    /// server's first month (SPEC 3.8), through two months after the current
    /// month. The past has no other limit.
    static func navigableMonths(now: Date = .now, calendar: Calendar = .current) -> ClosedRange<BudgetMonth> {
        BudgetMonth(year: 1900, month: 1)...current(now: now, calendar: calendar).adding(months: 2)
    }

    /// This month, moved into `range` if it lies outside it.
    func clamped(to range: ClosedRange<BudgetMonth>) -> BudgetMonth {
        min(max(self, range.lowerBound), range.upperBound)
    }

    /// The months from `first` through `last`, inclusive.
    static func range(from first: BudgetMonth, through last: BudgetMonth) -> [BudgetMonth] {
        var months: [BudgetMonth] = []
        var next = first
        while next <= last {
            months.append(next)
            next = next.adding(months: 1)
        }
        return months
    }
}

private extension Int {
    func floorDiv(_ d: Int) -> Int { Int((Double(self) / Double(d)).rounded(.down)) }
    func floorMod(_ d: Int) -> Int { self - floorDiv(d) * d }
}

/// A category's target (SPEC 18.3).
struct BudgetTarget: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case setAside = "set_aside"
        case refill

        var id: String { rawValue }
        var title: String {
            switch self {
            case .setAside: "Set Aside"
            case .refill: "Refill"
            }
        }
    }

    let type: Kind
    let amount: Int
    /// The day of the month it's due, or `nil` for the month's last day.
    let byDate: Int?
    let startMonth: String

    private enum CodingKeys: String, CodingKey { case type, amount, byDate, startMonth }
}

/// A target as a request sends it (SPEC 18.3). `by_date` is always written,
/// as `null` for the month's last day, and `start_month` is always sent.
struct TargetInput: Encodable, Hashable, Sendable {
    var type: BudgetTarget.Kind
    var amount: Int
    var byDate: Int?
    var startMonth: String

    private enum CodingKeys: String, CodingKey { case type, amount, byDate, startMonth }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(amount, forKey: .amount)
        if let byDate {
            try container.encode(byDate, forKey: .byDate)
        } else {
            try container.encodeNil(forKey: .byDate)
        }
        try container.encode(startMonth, forKey: .startMonth)
    }

    /// The month a new target starts in by default: the viewed month, or the
    /// current one when the viewed month is in the past (SPEC 18.3).
    static func defaultStartMonth(viewing viewed: BudgetMonth, current: BudgetMonth) -> BudgetMonth {
        max(viewed, current)
    }
}

/// The body of `PATCH /plans/{plan}/categories/{id}` with a target, or with
/// an explicit `"target": null` to remove it (SPEC 18.4).
struct TargetPatch: Encodable, Sendable {
    var target: TargetInput?

    private enum CodingKeys: String, CodingKey { case target }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let target {
            try container.encode(target, forKey: .target)
        } else {
            try container.encodeNil(forKey: .target)
        }
    }
}

struct AssignedPatch: Encodable, Sendable {
    var assigned: Int
}

/// The body of `PATCH /plans/{plan}/categories/{id}` for a user category
/// (SPEC 7.6). Only the fields that are set are sent. `note` is doubly
/// optional so that `.some(nil)` sends an explicit `null`, which clears it.
struct CategoryPatch: Encodable, Sendable, Equatable {
    var name: String?
    var note: String??
    var groupId: CategoryGroup.ID?

    var isEmpty: Bool { self == CategoryPatch() }

    private enum CodingKeys: String, CodingKey { case name, note, groupId }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        if let note {
            if let note {
                try container.encode(note, forKey: .note)
            } else {
                try container.encodeNil(forKey: .note)
            }
        }
        try container.encodeIfPresent(groupId, forKey: .groupId)
    }
}

/// A category's entry in a month (SPEC 11.3, 18.5).
struct MonthCategory: Codable, Identifiable, Hashable, Sendable {
    let categoryId: Category.ID
    var assigned: Int
    var activity: Int
    var available: Int
    var cashOverspending: Int
    var creditOverspending: Int
    var target: BudgetTarget?
    /// `YYYY-MM-DD`.
    var due: String?
    var underfunded: Int?

    var id: Category.ID { categoryId }
}

/// A month of the plan (SPEC 11.6).
struct MonthBudget: Codable, Hashable, Sendable {
    var income: Int
    var cashAdvances: Int
    var assigned: Int
    var activity: Int
    var cashOverspendingLastMonth: Int
    var leftOverFromLastMonth: Int
    var assignedInFuture: Int
    var readyToAssign: Int
    var underfunded: Int
    var categories: [MonthCategory]

    func entry(for id: Category.ID) -> MonthCategory? {
        categories.first { $0.categoryId == id }
    }
}

extension MonthCategory {
    /// "Refill 4,000.00 · due Nov 15 · 1,200.00 to go", or "" without a target.
    func targetText(currencyCode: String, locale: Locale = .current) -> String {
        guard let target else { return "" }
        var parts = ["\(target.type.title) \(Money.format(target.amount, currencyCode: currencyCode, locale: locale))"]
        if let due, let date = Self.dueFormatter.date(from: due) {
            parts.append("due " + date.formatted(
                Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: .gmt)
                    .month(.abbreviated).day()
            ))
        }
        if let underfunded, underfunded > 0 {
            parts.append("\(Money.format(underfunded, currencyCode: currencyCode, locale: locale)) to go")
        }
        return parts.joined(separator: " · ")
    }

    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
