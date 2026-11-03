import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// One recorded exchange with the real server routes: what the app sent and what came back.
/// Recorded against a throwaway database with invented data; see the package README.
struct Fixture: Decodable {
    struct Request: Decodable {
        let method: String
        let path: String
        let query: [String: String]
        let authorization: String?
        let body: JSONValue?
    }

    struct Response: Decodable {
        let status: Int
        let headers: [String: String]
        let body: JSONValue
    }

    let name: String
    /// The server commit this exchange was recorded from live, or nil for a file not recorded live.
    let recordedFrom: String?
    let request: Request
    let response: Response

    private enum CodingKeys: String, CodingKey {
        case recordedFrom, request, response
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = ""
        recordedFrom = try container.decodeIfPresent(String.self, forKey: .recordedFrom)
        request = try container.decode(Request.self, forKey: .request)
        response = try container.decode(Response.self, forKey: .response)
    }

    private init(name: String, copying other: Fixture) {
        self.name = name
        recordedFrom = other.recordedFrom
        request = other.request
        response = other.response
    }

    static func load(_ name: String) throws -> Fixture {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/contract"),
            "No fixture named \(name)"
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return Fixture(name: name, copying: fixture)
    }

    static func all() throws -> [Fixture] {
        let directory = try #require(Bundle.module.url(forResource: "contract", withExtension: nil, subdirectory: "Fixtures"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
        return try names.sorted().map(load)
    }

    /// The response body as bytes, as the server sent it.
    var responseData: Data {
        get throws { try JSONEncoder().encode(response.body) }
    }

    /// Decodes the recorded response body as a model, the way the client does.
    func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        try QBankJSON.decoder.decode(T.self, from: responseData)
    }
}

/// Answers each request with the next recorded response and keeps every request it was sent.
/// Nothing in a test run reaches the network.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    private struct State {
        var queue: [Result<(Data, HTTPURLResponse), any Error>]
        var sent: [URLRequest] = []
    }

    private let state: Mutex<State>

    init(_ fixtures: [Fixture]) throws {
        state = Mutex(State(queue: try fixtures.map { fixture in
            let headers = fixture.response.headers.merging(["Content-Type": "application/json"]) { old, _ in old }
            let response = HTTPURLResponse(url: URL(string: "https://qbank.invalid")!, statusCode: fixture.response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return .success((try fixture.responseData, response))
        }))
    }

    convenience init(_ names: String...) throws {
        try self.init(names.map(Fixture.load))
    }

    /// Answers with a raw status and body, for responses no fixture has, such as a proxy's HTML page.
    init(status: Int, body: String, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: URL(string: "https://qbank.invalid")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        state = Mutex(State(queue: [.success((Data(body.utf8), response))]))
    }

    /// Answers each request in turn with a 200 and the next body, for responses no recording has yet.
    init(bodies: [Data]) {
        let response = HTTPURLResponse(url: URL(string: "https://qbank.invalid")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        state = Mutex(State(queue: bodies.map { .success(($0, response)) }))
    }

    /// Fails every request with this error.
    init(failing error: any Error, times: Int = 1) {
        state = Mutex(State(queue: Array(repeating: .failure(error), count: times)))
    }

    var requests: [URLRequest] {
        state.withLock { $0.sent }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Result<(Data, HTTPURLResponse), any Error> = state.withLock { state in
            state.sent.append(request)
            guard !state.queue.isEmpty else { return .failure(UnexpectedRequest(request: request)) }
            return state.queue.removeFirst()
        }
        return try next.get()
    }

    struct UnexpectedRequest: Error {
        let request: URLRequest
    }
}

enum TestClient {
    static let baseURL = URL(string: "https://qbank.invalid")!

    /// A client signed in with the fixtures' placeholder token.
    static func make(_ transport: FixtureTransport, token: String? = "synthetic-session-token") -> (QBankClient, InMemorySessionStore) {
        let store = InMemorySessionStore(token.map { StoredSession(token: $0) })
        let client = QBankClient(configuration: APIConfiguration(baseURL: baseURL), transport: transport, sessionStore: store)
        return (client, store)
    }
}

/// Checks that the client sent what the recorded request sent: method, path, query, bearer token, and JSON body.
func expectRequest(_ request: URLRequest?, matches fixture: Fixture, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let request = try #require(request, "No request was sent", sourceLocation: sourceLocation)
    let url = try #require(request.url, sourceLocation: sourceLocation)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false), sourceLocation: sourceLocation)
    #expect(request.httpMethod == fixture.request.method, sourceLocation: sourceLocation)
    #expect(components.path == fixture.request.path, sourceLocation: sourceLocation)
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query == fixture.request.query, sourceLocation: sourceLocation)
    #expect(request.value(forHTTPHeaderField: "Authorization") == fixture.request.authorization, sourceLocation: sourceLocation)
    if let expected = fixture.request.body {
        let body = try #require(request.httpBody, "No body was sent", sourceLocation: sourceLocation)
        #expect(try JSONDecoder().decode(JSONValue.self, from: body) == expected, sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", sourceLocation: sourceLocation)
    } else {
        #expect(request.httpBody == nil, sourceLocation: sourceLocation)
    }
}
