import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Contract: the recordings themselves")
struct FixtureTests {
    /// Every error the server sent decodes into a typed error with its code and message. The
    /// import's conflict is the route's own answer, not an error body.
    @Test func everyErrorBodyDecodes() throws {
        let failures = try Fixture.all().filter { $0.response.status >= 400 && $0.response.body["conflict"] == nil }
        #expect(failures.count >= 10)
        for fixture in failures {
            let response = HTTPURLResponse(url: TestClient.baseURL, statusCode: fixture.response.status, httpVersion: nil, headerFields: fixture.response.headers)!
            let error = QBankClient.failure(status: fixture.response.status, data: try fixture.responseData, response: response)
            guard case .server(let server) = error else {
                Issue.record("\(fixture.name) did not decode as a server error")
                continue
            }
            #expect(server.code.rawValue == fixture.response.body["error"]?.stringValue, "\(fixture.name)")
            #expect(!server.message.isEmpty, "\(fixture.name)")
        }
    }

    /// Every recorded call is a path and method the pinned OpenAPI file documents, with that status.
    @Test func everyRecordingIsInTheOpenAPIFile() throws {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        let spec = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let paths)? = spec["paths"] else {
            Issue.record("openapi.json has no paths")
            return
        }
        for fixture in try Fixture.all() {
            // A literal path such as /api/passkeys/options wins over a template beside it, /api/passkeys/{id}.
            let template = paths.keys.first { $0 == fixture.request.path }
                ?? paths.keys.first { matches(template: $0, path: fixture.request.path) }
            let operation = template.flatMap { paths[$0]?[fixture.request.method.lowercased()] }
            #expect(operation != nil, "\(fixture.name): \(fixture.request.method) \(fixture.request.path) is not in openapi.json")
            #expect(operation?["responses"]?[String(fixture.response.status)] != nil, "\(fixture.name): status \(fixture.response.status) is not documented")
        }
    }

    /// The recordings hold no real session token, only placeholders.
    @Test func recordingsHoldOnlyPlaceholderTokens() throws {
        for fixture in try Fixture.all() {
            if let authorization = fixture.request.authorization {
                #expect(authorization.hasPrefix("Bearer synthetic-"), "\(fixture.name)")
            }
            if let token = fixture.response.body["token"]?.stringValue {
                #expect(token.hasPrefix("synthetic-"), "\(fixture.name)")
            }
        }
    }

    private func matches(template: String, path: String) -> Bool {
        let left = template.split(separator: "/")
        let right = path.split(separator: "/")
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
    }
}
