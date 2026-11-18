import Foundation

/// A plan (SPEC section 4).
struct Plan: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var currencyCode: String
}

/// A typed client for the server's HTTP API (`spec/SPEC.md`).
struct APIClient: Sendable {
    struct ServerError: LocalizedError {
        let status: Int
        let message: String

        var errorDescription: String? { "\(message) (HTTP \(status))" }
    }

    let baseURL: URL
    var session: URLSession = .shared

    /// SPEC 2.1: `GET /health` returns 200 with the body `ok`.
    func health() async throws -> Bool {
        let (data, _) = try await send("GET", "health")
        return data == Data("ok".utf8)
    }

    /// SPEC 4.2: every plan, oldest first.
    func plans() async throws -> [Plan] {
        try decode(await send("GET", "plans").0)
    }

    /// SPEC 4.1. A `nil` currency code leaves the server's default (USD).
    func createPlan(name: String, currencyCode: String? = nil) async throws -> Plan {
        struct Body: Encodable { let name: String; let currencyCode: String? }
        return try decode(
            await send("POST", "plans", body: Body(name: name, currencyCode: currencyCode)).0
        )
    }

    /// SPEC 5.6: the plan's accounts, oldest first.
    func accounts(planID: Plan.ID) async throws -> [Account] {
        try decode(await send("GET", "plans/\(planID)/accounts").0)
    }

    /// SPEC 5.2.
    func createAccount(planID: Plan.ID, _ account: NewAccount) async throws -> Account {
        try decode(await send("POST", "plans/\(planID)/accounts", body: account).0)
    }

    /// SPEC 5.7 and 5.8.
    func updateAccount(
        planID: Plan.ID, accountID: Account.ID, _ patch: AccountPatch
    ) async throws -> Account {
        try decode(await send("PATCH", "plans/\(planID)/accounts/\(accountID)", body: patch).0)
    }

    /// SPEC 5.9: fails with 409 if the account has any transactions.
    func deleteAccount(planID: Plan.ID, accountID: Account.ID) async throws {
        _ = try await send("DELETE", "plans/\(planID)/accounts/\(accountID)")
    }

    // MARK: - Plumbing

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// SPEC 3.2: error responses are `{"error": "..."}`.
    private struct ErrorBody: Decodable { let error: String }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try Self.decoder.decode(T.self, from: data)
    }

    private func send(
        _ method: String, _ path: String, body: (some Encodable)? = nil as Never?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? Self.decoder.decode(ErrorBody.self, from: data))?.error
            throw ServerError(
                status: http.statusCode,
                message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        return (data, http)
    }
}
