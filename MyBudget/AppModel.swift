import Foundation
import Observation
import os

private let log = Logger(subsystem: "local.mybudget.MyBudget", category: "server")

/// The app's state: the connection to the bundled server, its plans, and the
/// plan the window has open.
@MainActor
@Observable
final class AppModel {
    enum Connection {
        case starting
        case connected(URL)
        case failed(String)
    }

    private(set) var connection: Connection = .starting
    private(set) var plans: [Plan] = []
    /// The plan the window shows. `nil` shows the plan chooser.
    private(set) var openPlan: PlanModel?

    @ObservationIgnored private let server: ServerProcess
    @ObservationIgnored private var client: APIClient?
    @ObservationIgnored private let defaults: UserDefaults

    /// The plan to reopen at launch. Ids are never reused (SPEC 3.5), so a
    /// stale one simply isn't found.
    private static let lastPlanKey = "LastOpenPlanID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        server = ServerProcess(dataDirectory: Self.usesSampleData ? nil : ServerProcess.defaultDataDirectory)
    }

    /// Whether this launch shows a throwaway sample plan instead of the saved
    /// plans: `open --env MYBUDGET_SAMPLE_DATA=1 MyBudget.app`, Debug builds only.
    private static var usesSampleData: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MYBUDGET_SAMPLE_DATA"] == "1"
        #else
        false
        #endif
    }

    func start() async {
        do {
            let url = try await server.start()
            let client = APIClient(baseURL: url)
            guard try await client.health() else {
                throw APIClient.ServerError(status: 200, message: "GET /health didn't return ok")
            }
            plans = try await client.plans()
            #if DEBUG
            if Self.usesSampleData {
                let sample = try await Self.addSampleData(client)
                plans = [sample]
            }
            #endif
            self.client = client
            connection = .connected(url)
            log.info("Connected to \(url.absoluteString, privacy: .public), \(self.plans.count) plans")
        } catch {
            server.stop()
            log.error("Server failed: \(error.localizedDescription, privacy: .public)")
            connection = .failed(error.localizedDescription)
            return
        }

        if Self.usesSampleData, let sample = plans.first {
            try? await open(sample)
        } else if let id = defaults.string(forKey: Self.lastPlanKey),
                  let plan = plans.first(where: { $0.id == id }) {
            try? await open(plan)
        }
    }

    func stop() {
        server.stop()
    }

    func createPlan(name: String, currencyCode: String) async throws -> Plan {
        let client = try requireClient()
        let plan = try await client.createPlan(name: name, currencyCode: currencyCode)
        plans.append(plan)
        return plan
    }

    /// Loads the plan's accounts, then shows it. A plan opened while showing
    /// sample data isn't saved, so it isn't remembered either.
    func open(_ plan: Plan) async throws {
        let model = PlanModel(plan: plan, client: try requireClient())
        try await model.reload()
        openPlan = model
        if !Self.usesSampleData {
            defaults.set(plan.id, forKey: Self.lastPlanKey)
        }
        log.info("Opened plan \(plan.id, privacy: .public)")
    }

    /// Goes back to the plan chooser, which the next launch shows too.
    func closePlan() {
        openPlan = nil
        if !Self.usesSampleData {
            defaults.removeObject(forKey: Self.lastPlanKey)
        }
    }

    #if DEBUG
    /// A plan to look at the UI with. The server keeps it only in memory, so
    /// it never mixes with the saved plans and each launch starts it afresh.
    private static func addSampleData(_ client: APIClient) async throws -> Plan {
        let plan = try await client.createPlan(name: "Household")
        let date = PlanDate.string(from: .now)
        let accounts: [(String, AccountType, Int)] = [
            ("Everyday Checking", .checking, 2_534_120),
            ("Emergency Fund", .savings, 8_000_000),
            ("Wallet", .cash, 62_000),
            ("Visa", .creditCard, -412_870),
            ("Home Equity Line", .lineOfCredit, 0),
            ("House", .otherAsset, 350_000_000),
            ("Car Loan", .otherLiability, -14_250_000),
            ("Old Savings", .savings, 0),
        ]
        for (name, type, balance) in accounts {
            let account = try await client.createAccount(planID: plan.id, NewAccount(
                name: name, type: type, startingBalance: balance,
                startingDate: balance == 0 ? nil : date
            ))
            if name == "Old Savings" {
                _ = try await client.updateAccount(
                    planID: plan.id, accountID: account.id, AccountPatch(closed: true)
                )
            }
        }
        return plan
    }
    #endif

    private func requireClient() throws -> APIClient {
        guard let client else { throw NotConnected() }
        return client
    }

    struct NotConnected: LocalizedError {
        var errorDescription: String? { "The server isn't running." }
    }
}
