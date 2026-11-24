import Foundation
import Testing
@testable import MyBudget

struct BudgetTests {
    private static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try APIClient.encoder.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func decodesAMonth() throws {
        let json = """
        {"income": 3000000, "cash_advances": 0, "assigned": 1600000, "activity": -200000,
         "cash_overspending_last_month": 0, "left_over_from_last_month": 0, "assigned_in_future": 1200000,
         "ready_to_assign": 200000, "underfunded": 120000,
         "uncategorized": {"category_id": null, "assigned": 0, "activity": 0, "available": 0,
                           "cash_overspending": 0, "credit_overspending": 0, "target": null, "due": null, "underfunded": null},
         "categories": [
          {"category_id": "GROCERIES_ID", "assigned": 0, "activity": 0, "available": 280000,
           "cash_overspending": 0, "credit_overspending": 0,
           "target": {"type": "refill", "amount": 400000, "by_date": 15, "start_month": "2026-11"},
           "due": "2026-11-15", "underfunded": 120000},
          {"category_id": "DINING_ID", "assigned": 0, "activity": -80000, "available": -80000,
           "cash_overspending": 80000, "credit_overspending": 0, "target": null, "due": null, "underfunded": null}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let month = try decoder.decode(MonthBudget.self, from: Data(json.utf8))
        #expect(month.readyToAssign == 200_000)
        #expect(month.assignedInFuture == 1_200_000)
        #expect(month.categories.count == 2)
        let groceries = try #require(month.entry(for: "GROCERIES_ID"))
        #expect(groceries.target?.type == .refill)
        #expect(groceries.target?.byDate == 15)
        #expect(groceries.underfunded == 120_000)
        #expect(groceries.targetText(currencyCode: "USD", locale: Locale(identifier: "en_US"))
                == "Refill $400.00 · due Nov 15 · $120.00 to go")
        #expect(month.entry(for: "DINING_ID")?.targetText(currencyCode: "USD") == "")
    }

    @Test func removingATargetSendsAnExplicitNull() throws {
        let data = try APIClient.encoder.encode(TargetPatch(target: nil))
        #expect(String(decoding: data, as: UTF8.self) == #"{"target":null}"#)
    }

    @Test func targetWithoutADayEncodesByDateAsNull() throws {
        let patch = TargetPatch(target: TargetInput(type: .setAside, amount: 300_000, byDate: nil, startMonth: "2026-12"))
        let body = try Self.json(patch)
        let target = try #require(body["target"] as? [String: Any])
        #expect(target.keys.sorted() == ["amount", "by_date", "start_month", "type"])
        #expect(target["by_date"] is NSNull)
        #expect(target["type"] as? String == "set_aside")
        #expect(target["start_month"] as? String == "2026-12")

        let dated = try Self.json(TargetInput(type: .refill, amount: 1, byDate: 15, startMonth: "2026-11"))
        #expect(dated["by_date"] as? Int == 15)
    }

    @Test func startMonthDefaultsToTheViewedMonthUnlessPast() {
        let current = BudgetMonth(year: 2026, month: 11)
        #expect(TargetInput.defaultStartMonth(viewing: BudgetMonth(year: 2027, month: 2), current: current)
                == BudgetMonth(year: 2027, month: 2))
        #expect(TargetInput.defaultStartMonth(viewing: BudgetMonth(year: 2026, month: 9), current: current) == current)
        #expect(TargetInput.defaultStartMonth(viewing: current, current: current) == current)
    }

    @Test func monthsStepAcrossYears() {
        let december = BudgetMonth(year: 2026, month: 12)
        #expect(december.adding(months: 1) == BudgetMonth(year: 2027, month: 1))
        #expect(BudgetMonth(year: 2027, month: 1).adding(months: -1).key == "2026-12")
        #expect(BudgetMonth(year: 2026, month: 1).adding(months: -13).key == "2024-12")
        #expect(BudgetMonth(key: "2026-11") == BudgetMonth(year: 2026, month: 11))
        #expect(BudgetMonth(key: "2026-13") == nil)
    }

    @Test func navigationStopsTwoMonthsPastThisOne() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24)))
        let range = BudgetMonth.navigableMonths(now: now, calendar: calendar)

        #expect(range.upperBound == BudgetMonth(year: 2027, month: 1))
        #expect(range.lowerBound == BudgetMonth(year: 1900, month: 1))
        // Three months ahead is clamped to two; the past is not limited.
        #expect(BudgetMonth(year: 2027, month: 2).clamped(to: range) == BudgetMonth(year: 2027, month: 1))
        #expect(BudgetMonth(year: 2027, month: 1).clamped(to: range) == BudgetMonth(year: 2027, month: 1))
        #expect(BudgetMonth(year: 2019, month: 5).clamped(to: range) == BudgetMonth(year: 2019, month: 5))
        #expect(BudgetMonth(year: 1800, month: 5).clamped(to: range) == BudgetMonth(year: 1900, month: 1))
    }

    @Test func categoryPatchSendsOnlyWhatItSetAndAnExplicitNullNote() throws {
        let rename = try Self.json(CategoryPatch(name: "Food"))
        #expect(rename.keys.sorted() == ["name"])

        let clearNote = try Self.json(CategoryPatch(note: .some(nil)))
        #expect(clearNote.keys.sorted() == ["note"])
        #expect(clearNote["note"] is NSNull)

        let move = try Self.json(CategoryPatch(groupId: "BILLS_ID"))
        #expect(move["group_id"] as? String == "BILLS_ID")
        #expect(move.keys.sorted() == ["group_id"])

        #expect(CategoryPatch().isEmpty)
        #expect(!CategoryPatch(note: .some("due on the 1st")).isEmpty)
    }
}
