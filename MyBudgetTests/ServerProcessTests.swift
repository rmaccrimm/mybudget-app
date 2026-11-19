import Foundation
import Testing
@testable import MyBudget

struct ListeningLineTests {
    @Test func parsesTheAddressTheServerPrints() throws {
        let url = try ServerProcess.baseURL(fromListeningLine: "listening on 127.0.0.1:54321")
        #expect(url.absoluteString == "http://127.0.0.1:54321")
        #expect(url.port == 54321)
    }

    @Test(arguments: [
        "",
        "listening on",
        "listening on 127.0.0.1",
        "Listening on 127.0.0.1:8080",
        "error: address in use",
    ])
    func rejectsAnythingElse(line: String) {
        #expect(throws: ServerProcess.LaunchError.self) {
            try ServerProcess.baseURL(fromListeningLine: line)
        }
    }
}

/// These start the server bundled in the host app, so they cover the build
/// phase, the signing and the sandbox as well as the client.
@MainActor
@Suite(.serialized)
struct BundledServerTests {
    @Test func startsAndAnswersHealth() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        #expect(try await client.health())
    }

    @Test func createsAndListsPlans() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())

        let plan = try await client.createPlan(name: "Household")
        #expect(plan.name == "Household")
        #expect(plan.currencyCode == "USD")
        #expect(try await client.plans() == [plan])
    }

    @Test func reportsTheServersErrorMessage() async throws {
        let server = ServerProcess(dataDirectory: nil)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())

        // SPEC 3.9: a name needs a character that isn't whitespace.
        let error = try await #require(throws: APIClient.ServerError.self) {
            try await client.createPlan(name: " ")
        }
        #expect(error.status == 400)
        #expect(!error.message.isEmpty)
    }

    @Test func eachServerGetsItsOwnPort() async throws {
        let first = ServerProcess(dataDirectory: nil), second = ServerProcess(dataDirectory: nil)
        defer { first.stop(); second.stop() }
        let a = try await first.start(), b = try await second.start()
        #expect(a.port != b.port)
    }
}

/// The bundled server with a data directory (SPEC section 15). Each test
/// gets its own directory, so the tests never see the app's saved plans.
@MainActor
@Suite(.serialized)
struct PersistenceTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MyBudgetTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func keepsPlansAndAccountsAcrossRestarts() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan: Plan, account: Account
        do {
            let server = ServerProcess(dataDirectory: directory)
            defer { server.stop() }
            let client = APIClient(baseURL: try await server.start())
            plan = try await client.createPlan(name: "Household")
            account = try await client.createAccount(planID: plan.id, NewAccount(
                name: "Checking", type: .checking, startingBalance: 125_000,
                startingDate: "2026-11-01"
            ))
        }

        // SPEC 15.2: one file per plan, named after it.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(files == ["Household.sqlite"])

        let server = ServerProcess(dataDirectory: directory)
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        #expect(try await client.plans() == [plan])
        #expect(try await client.accounts(planID: plan.id) == [account])
    }

    @Test func reportsWhyItCantUseTheDirectory() async throws {
        // SPEC 15.1: a directory the server can't create stops it starting.
        let file = directory.appending(path: "not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: file)

        let server = ServerProcess(dataDirectory: file.appending(path: "data"))
        defer { server.stop() }
        let error = try await #require(throws: ServerProcess.LaunchError.self) {
            try await server.start()
        }
        guard case .exitedBeforeListening(let status, let message) = error else {
            Issue.record("Expected the server to exit, got \(error)")
            return
        }
        #expect(status != 0)
        #expect(!message.isEmpty)
    }
}

