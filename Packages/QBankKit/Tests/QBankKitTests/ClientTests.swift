import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Client")
struct ClientTests {
    @Test func productionIsTheLiveServer() {
        #expect(APIConfiguration.production.baseURL.absoluteString == "https://qbank.dimitrygallego.com")
    }

    @Test func noSessionMeansNothingIsSent() async throws {
        let transport = try FixtureTransport("semesters")
        let (client, _) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        #expect(error == .notSignedIn)
        #expect(error?.needsSignIn == true)
        #expect(transport.requests.isEmpty)
    }

    @Test func signInSendsNoBearerToken() async throws {
        let transport = try FixtureTransport("sign-in")
        let (client, _) = TestClient.make(transport, token: "an-old-token")
        try await client.signIn(email: "student@example.com", password: "synthetic-pass-1")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func signUpSendsNoBearerToken() async throws {
        let transport = try FixtureTransport("sign-up")
        let (client, _) = TestClient.make(transport, token: "an-old-token")
        try await client.signUp(email: "new.user@example.com", password: "synthetic-pass-2")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// The account was made but its sign-in failed: nothing is stored, and she signs in next.
    @Test func signUpMadeButNotSignedInStoresNothing() async throws {
        let transport = FixtureTransport(
            status: 502,
            body: #"{"error": "auth_failed", "message": "Your account was made, but signing in failed. Sign in to continue."}"#
        )
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) { try await client.signUp(email: "a@example.com", password: "synthetic-pass-2") }
        #expect(error?.serverCode == .authFailed)
        #expect(try store.load() == nil)
    }

    @Test func requestsAskForJSONAndCarryNoCookies() async throws {
        let transport = try FixtureTransport("semesters")
        let (client, _) = TestClient.make(transport)
        _ = try await client.catalog()
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.timeoutInterval == 30)
    }

    @Test func noSignalIsATransportError() async throws {
        let transport = FixtureTransport(failing: URLError(.notConnectedToInternet))
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        #expect(error == .transport(.notConnectedToInternet))
        #expect(error?.isTemporary == true)
    }

    @Test func cancellationIsReportedAsSuch() async throws {
        let transport = FixtureTransport(failing: URLError(.cancelled))
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        #expect(error == .cancelled)
    }

    @Test func proxyErrorPageIsUnexpectedAndTemporary() async throws {
        let transport = FixtureTransport(status: 502, body: "<html><body>Bad Gateway</body></html>")
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        guard case .unexpectedResponse(let status, let detail)? = error else {
            Issue.record("Expected an unexpected response, got \(String(describing: error))")
            return
        }
        #expect(status == 502)
        #expect(detail.contains("Bad Gateway"))
        #expect(error?.isTemporary == true)
    }

    @Test func bodyThatDoesNotMatchTheModelIsUnexpected() async throws {
        let transport = FixtureTransport(status: 200, body: #"{"semesters": [{"id": 1}]}"#)
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        guard case .unexpectedResponse(let status, _)? = error else {
            Issue.record("Expected an unexpected response")
            return
        }
        #expect(status == 200)
        #expect(error?.isTemporary == false)
    }

    @Test func retryAfterHeaderFillsInAMissingBodyField() async throws {
        let transport = FixtureTransport(
            status: 429,
            body: #"{"error": "too_many_attempts", "message": "Too many tries."}"#,
            headers: ["Retry-After": "120"]
        )
        let (client, _) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) { try await client.signIn(email: "a@example.com", password: "b") }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error")
            return
        }
        #expect(server.retryAfterSeconds == 120)
    }

    @Test func unknownErrorCodesStillDecode() async throws {
        let transport = FixtureTransport(status: 400, body: #"{"error": "something_new", "message": "A new refusal."}"#)
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        #expect(error?.serverCode == "something_new")
    }

    @Test func signOutForgetsTheSessionEvenWithoutSignal() async throws {
        let transport = FixtureTransport(failing: URLError(.notConnectedToInternet))
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.signOut() }
        #expect(error == .transport(.notConnectedToInternet))
        #expect(try store.load() == nil)
    }

    @Test func signOutOfAnEndedSessionIsQuiet() async throws {
        let transport = try FixtureTransport("session-after-sign-out")
        let (client, store) = TestClient.make(transport)
        try await client.signOut()
        #expect(try store.load() == nil)
    }

    /// Without an answer the other devices may still be signed in, so this one stays signed in too.
    @Test func signOutEverywhereWithoutSignalKeepsTheSession() async throws {
        let transport = FixtureTransport(failing: URLError(.notConnectedToInternet))
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.signOutEverywhere() }
        #expect(error == .transport(.notConnectedToInternet))
        #expect(try store.load()?.token == "synthetic-session-token")
    }

    @Test func signOutEverywhereTheServerCouldNotEndKeepsTheSession() async throws {
        let transport = FixtureTransport(status: 502, body: #"{"error": "auth_failed", "message": "Signing out everywhere did not work. Try again."}"#)
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.signOutEverywhere() }
        #expect(error?.serverCode == .authFailed)
        #expect(error?.needsSignIn == false)
        #expect(try store.load()?.token == "synthetic-session-token")
    }

    @Test func signOutWithoutASessionSendsNothing() async throws {
        let transport = try FixtureTransport("sign-out")
        let (client, _) = TestClient.make(transport, token: nil)
        try await client.signOut()
        #expect(transport.requests.isEmpty)
    }

    @Test func baseURLWithAPathPrefix() async throws {
        let transport = try FixtureTransport("semesters")
        let store = InMemorySessionStore(StoredSession(token: "synthetic-session-token"))
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://example.invalid/qbank/")!),
            transport: transport,
            sessionStore: store
        )
        _ = try await client.catalog()
        #expect(transport.requests.first?.url?.absoluteString == "https://example.invalid/qbank/api/semesters")
    }

    @Test func storageFailureIsReported() async throws {
        let transport = try FixtureTransport("semesters")
        let client = QBankClient(configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: transport, sessionStore: BrokenSessionStore())
        let error = await #expect(throws: QBankError.self) { try await client.catalog() }
        guard case .storage(let storage)? = error else {
            Issue.record("Expected a storage error")
            return
        }
        #expect(storage.status == -25308)
        #expect(transport.requests.isEmpty)
    }
}

struct BrokenSessionStore: SessionStore {
    func load() throws(StorageError) -> StoredSession? {
        throw StorageError(operation: "read session", reason: "locked", status: -25308)
    }

    func save(_ session: StoredSession) throws(StorageError) {
        throw StorageError(operation: "save session", reason: "locked", status: -25308)
    }

    func clear() throws(StorageError) {
        throw StorageError(operation: "clear session", reason: "locked", status: -25308)
    }
}
