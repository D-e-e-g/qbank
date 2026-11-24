import Foundation
import Synchronization
import Testing

@testable import QBankKit

/// Which side a free account's request goes to: the bank on the phone for the bank's paths, the
/// network for the account's. Invented paths and data only.
@Suite struct BankRoutedTransportTests {
    /// Answers every request with its own name, and remembers the paths it was asked.
    private final class Named: HTTPTransport {
        let name: String
        private let seen = Mutex<[String]>([])

        init(_ name: String) { self.name = name }

        var paths: [String] { seen.withLock { $0 } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            seen.withLock { $0.append("\(request.httpMethod ?? "GET") \(url.path)") }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(name.utf8), response)
        }
    }

    private func who(_ transport: BankRoutedTransport, _ method: String, _ path: String) async throws -> String {
        var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid\(path)?x=1")))
        request.httpMethod = method
        let (data, _) = try await transport.send(request)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func theBanksPathsGoToTheBankAndTheAccountsGoToTheNetwork() async throws {
        let bank = Named("bank")
        let network = Named("network")
        let transport = BankRoutedTransport(bank: bank, account: network)
        let bankPaths = [
            "GET /api/semesters", "POST /api/semesters", "PATCH /api/semesters/s1", "POST /api/courses", "GET /api/courses/c1",
            "GET /api/courses/c1/review/practice", "POST /api/courses/c1/exams", "POST /api/topics", "PUT /api/topic-order",
            "PUT /api/courses/c1/folder-order", "POST /api/courses/c1/folders", "PATCH /api/folders/f1", "POST /api/courses/c1/course-exams",
            "PUT /api/course-exams/p1", "GET /api/practice-sets/p1", "POST /api/practice-sets/p1/start-over", "POST /api/imports",
            "POST /api/imports/check", "POST /api/attempts", "GET /api/exams/e1", "POST /api/exams/e1/finish", "GET /api/deleted-courses",
            "GET /api/me/place", "PUT /api/me/place",
        ]
        for line in bankPaths {
            let parts = line.split(separator: " ")
            #expect(try await who(transport, String(parts[0]), String(parts[1])) == "bank", "\(line) is the bank's")
        }
        let accountPaths = [
            "GET /health", "POST /api/sign-in/password", "POST /api/sign-out", "POST /api/sign-out/everywhere", "GET /api/session",
            "DELETE /api/me", "PUT /api/me/palette", "GET /api/me/export", "GET /api/me/bank", "GET /api/me/standing", "GET /api/question-maker",
            "POST /api/account/password", "GET /api/agent-keys", "GET /api/admin/students", "POST /api/sign-up",
            "GET /api/me/place/extra", "GET /api",
        ]
        for line in accountPaths {
            let parts = line.split(separator: " ")
            #expect(try await who(transport, String(parts[0]), String(parts[1])) == "network", "\(line) is the account's")
        }
        #expect(bank.paths.count == bankPaths.count)
        #expect(network.paths.count == accountPaths.count)
    }

    @Test func aPathThatOnlyStartsLikeABankPathIsNotTheBanks() {
        #expect(!BankRoutedTransport.isBankPath("/api/coursesX"))
        #expect(!BankRoutedTransport.isBankPath("/courses"))
        #expect(!BankRoutedTransport.isBankPath("/api/me/placement"))
        #expect(BankRoutedTransport.isBankPath("/api/courses"))
    }

    /// The bank answers a path it does not serve with its own 404, so nothing the bank owns is ever
    /// asked of the network.
    @Test func aBankPathTheBankDoesNotServeNeverReachesTheNetwork() async throws {
        let network = Named("network")
        let harness = try LocalBankHarness()
        let transport = BankRoutedTransport(bank: harness.bank, account: network)
        var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid/api/courses/c1/not-a-route")))
        request.httpMethod = "GET"
        let (_, response) = try await transport.send(request)
        #expect(response.statusCode == 404)
        #expect(network.paths.isEmpty)
    }

    @Test func aStudyRequestAnswersFromTheBankWithoutTheNetwork() async throws {
        let network = Named("network")
        let harness = try LocalBankHarness()
        let transport = BankRoutedTransport(bank: harness.bank, account: network)
        var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid/api/semesters")))
        request.httpMethod = "GET"
        let (data, response) = try await transport.send(request)
        #expect(response.statusCode == 200)
        let body = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(body["topics"]?.arrayValue?.isEmpty == true)
        #expect(network.paths.isEmpty)
    }
}
