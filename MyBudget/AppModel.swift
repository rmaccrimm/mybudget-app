import Foundation
import Observation
import os

private let log = Logger(subsystem: "local.mybudget.MyBudget", category: "server")

/// The app's state: the connection to the bundled server and the data shown.
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
    /// The last request that failed while connected, shown until the next success.
    private(set) var lastError: String?

    @ObservationIgnored private let server = ServerProcess()
    @ObservationIgnored private var client: APIClient?

    var isConnected: Bool { client != nil }

    func start() async {
        do {
            let url = try await server.start()
            let client = APIClient(baseURL: url)
            guard try await client.health() else {
                throw APIClient.ServerError(status: 200, message: "GET /health didn't return ok")
            }
            self.client = client
            connection = .connected(url)
            log.info("Connected to \(url.absoluteString, privacy: .public)")
            await reload()
        } catch {
            server.stop()
            log.error("Server failed: \(error.localizedDescription, privacy: .public)")
            connection = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server.stop()
    }

    func reload() async {
        await perform { client in
            plans = try await client.plans()
            log.info("Loaded \(self.plans.count) plans")
        }
    }

    func addPlan(named name: String) async {
        await perform { client in
            plans.append(try await client.createPlan(name: name))
        }
    }

    private func perform(_ work: (APIClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await work(client)
            lastError = nil
        } catch {
            log.error("Request failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}
