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
        let server = ServerProcess()
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())
        #expect(try await client.health())
    }

    @Test func createsAndListsPlans() async throws {
        let server = ServerProcess()
        defer { server.stop() }
        let client = APIClient(baseURL: try await server.start())

        let plan = try await client.createPlan(name: "Household")
        #expect(plan.name == "Household")
        #expect(plan.currencyCode == "USD")
        #expect(try await client.plans() == [plan])
    }

    @Test func reportsTheServersErrorMessage() async throws {
        let server = ServerProcess()
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
        let first = ServerProcess(), second = ServerProcess()
        defer { first.stop(); second.stop() }
        let a = try await first.start(), b = try await second.start()
        #expect(a.port != b.port)
    }
}
