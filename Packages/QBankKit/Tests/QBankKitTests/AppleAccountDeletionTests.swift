import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// Deleting a store account as the kit sends and keeps it: the body of `DELETE /api/me` for an account
/// with no password, the record of how far a delete has come, and erasing a bank on the phone. The
/// answers are shaped by the pinned contract's `DeleteAccount`, `AccountDeleted` and `Error` schemas;
/// there is no recording of this route for an account with no password, since only a real Apple token
/// gets past it. Invented data only.
@Suite("Deleting a store account")
struct AppleAccountDeletionTests {
    private static let request = AppleAccountDeletionRequest(
        identityToken: "synthetic.apple.token", nonce: String(repeating: "ab", count: 32), authorizationCode: "synthetic-apple-code")
    private static let session = StoredSession(
        token: "synthetic-session-token", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        account: Account(id: "a3", email: "person@privaterelay.appleid.com", name: "person", role: .student, mustChangePassword: false, origin: .store),
        appleUser: "001234.0a1b2c3d4e5f60718293a4b5c6d7e8f9.0123")

    private func client(_ transport: FixtureTransport, stored: StoredSession? = Self.session) -> (QBankClient, InMemorySessionStore) {
        let store = InMemorySessionStore(stored)
        return (QBankClient(configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: transport, sessionStore: store), store)
    }

    // MARK: The request

    @Test func theDeleteSendsAppleFreshSignInAndNoPassword() async throws {
        let transport = FixtureTransport(status: 200, body: #"{"status":"deleted"}"#)
        let (client, _) = client(transport)
        try await client.deleteAccount(confirmedWithApple: Self.request)
        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "DELETE")
        #expect(sent.url?.path() == "/api/me")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(sent.httpBody))
        #expect(body == ["identityToken": "synthetic.apple.token", "nonce": String(repeating: "ab", count: 32), "authorizationCode": "synthetic-apple-code"])
    }

    /// Every field the body sends is one the pinned `DeleteAccount` schema names, so the server reads it.
    @Test func theBodysFieldsAreThePinnedSchemas() throws {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        let spec = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let schema = try #require(spec["components"]?["schemas"]?["DeleteAccount"]?["properties"])
        guard case .object(let properties) = schema else {
            Issue.record("DeleteAccount has no properties")
            return
        }
        let sent = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(Self.request))
        #expect(Set(sent.keys).isSubset(of: Set(properties.keys)))
        #expect(Set(sent.keys) == ["identityToken", "nonce", "authorizationCode"])
    }

    /// The server deleted the account; forgetting the session is the app's last step, so it is kept.
    @Test func aDeleteLeavesTheSessionForTheAppToForget() async throws {
        let (client, store) = client(FixtureTransport(status: 200, body: #"{"status":"deleted"}"#))
        try await client.deleteAccount(confirmedWithApple: Self.request)
        #expect(try store.load() == Self.session)
    }

    @Test(arguments: [
        (400, "invalid_request", "Sign in with Apple again to delete this account."),
        (401, "invalid_apple_token", "Apple did not confirm it's you. Sign in with Apple again to delete your account."),
        (502, "apple_unreachable", "Apple could not be reached. Try again."),
        (503, "apple_sign_in_unavailable", "Sign in with Apple is not available yet."),
    ])
    func aRefusalIsThrownWithTheServersWords(status: Int, code: String, message: String) async throws {
        let (client, store) = client(FixtureTransport(status: status, body: #"{"error":"\#(code)","message":"\#(message)"}"#))
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteAccount(confirmedWithApple: Self.request)
        }
        guard case .server(let server)? = error else {
            Issue.record("not the server's refusal: \(String(describing: error))")
            return
        }
        #expect(server.status == status)
        #expect(server.code.rawValue == code)
        #expect(server.message == message)
        #expect(error?.needsSignIn == false, "a refusal is not an ended session")
        #expect(try store.load() == Self.session)
    }

    /// What an earlier delete of the account leaves: this phone's session is gone.
    @Test func aSessionTheServerNoLongerHasNeedsSignIn() async throws {
        let (client, _) = client(FixtureTransport(status: 401, body: #"{"error":"unauthenticated","message":"Sign in to continue."}"#))
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteAccount(confirmedWithApple: Self.request)
        }
        #expect(error?.needsSignIn == true)
    }

    // MARK: The record of a delete

    @Test func recordingAStepKeepsEverythingElseOfTheSession() throws {
        let (client, store) = client(FixtureTransport(status: 200, body: "{}"))
        try client.recordAccountDeletion(.erasingPhone)
        let erasing = try #require(try store.load())
        #expect(erasing.deletion == .erasingPhone)
        #expect(erasing.token == Self.session.token)
        #expect(erasing.expiresAt == Self.session.expiresAt)
        #expect(erasing.account == Self.session.account)
        #expect(erasing.appleUser == Self.session.appleUser)
        try client.recordAccountDeletion(.phoneErased)
        #expect(try store.load()?.deletion == .phoneErased)
    }

    @Test func recordingWithNoSessionIsRefused() throws {
        let (client, store) = client(FixtureTransport(status: 200, body: "{}"), stored: nil)
        #expect(throws: QBankError.self) {
            try client.recordAccountDeletion(.erasingPhone)
        }
        #expect(try store.load() == nil)
    }

    /// Checking the session with the server, as the app does before a delete, keeps the record.
    @Test func checkingTheSessionKeepsTheRecord() async throws {
        let user = #"{"id":"a3","email":"person@privaterelay.appleid.com","name":"person","role":"student","mustChangePassword":false,"palette":"slate","origin":"store"}"#
        let (client, store) = client(FixtureTransport(status: 200, body: #"{"user":\#(user),"expiresAt":"2027-11-24T00:00:00.000Z"}"#))
        try client.recordAccountDeletion(.phoneErased)
        _ = try await client.session()
        let stored = try #require(try store.load())
        #expect(stored.deletion == .phoneErased)
        #expect(stored.account?.palette == .slate)
    }

    @Test func aSessionKeptBeforeDeletesWereRecordedReadsWithNone() throws {
        let json = #"{"token":"synthetic-session-token","appleUser":"001234.abc.0123"}"#
        let stored = try QBankJSON.decoder.decode(StoredSession.self, from: Data(json.utf8))
        #expect(stored.deletion == nil)
        #expect(stored.appleUser == "001234.abc.0123")
        let recorded = StoredSession(token: "t", deletion: .phoneErased)
        #expect(try QBankJSON.decoder.decode(StoredSession.self, from: QBankJSON.encoder.encode(recorded)) == recorded)
    }

    // MARK: Erasing a bank

    @Test func erasingABankRemovesItsFolderAndOnlyThat() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try LocalStore.open(key: "kept.person", in: root)
        let erased = try LocalStore.open(key: "001234.erased.0123", in: root)
        let folder = try #require(erased.fileURL).deletingLastPathComponent()
        try "a safety copy".write(to: folder.appendingPathComponent("bank-2026-11-25.sqlite"), atomically: true, encoding: .utf8)
        erased.close()
        try LocalStore.erase(key: "001234.erased.0123", in: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: try #require(kept.fileURL).path), "another person's bank stays")
        // Opening the key again makes a new, empty bank.
        let reopened = try LocalStore.open(key: "001234.erased.0123", in: root)
        #expect(try reopened.read { try $0.value("SELECT count(*) FROM course") } == .integer(0))
    }

    @Test func erasingABankThatIsNotThereChangesNothing() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try LocalStore.erase(key: "never.opened", in: root)
        try LocalStore.erase(key: "never.opened", in: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aKeyThatIsNotOneFolderErasesNothing() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore.open(key: "kept.person", in: root)
        store.close()
        for key in ["..", "../Banks", "", ".hidden", "a/b"] {
            #expect(throws: StoreError.self) {
                try LocalStore.erase(key: key, in: root)
            }
        }
        #expect(FileManager.default.fileExists(atPath: try #require(store.fileURL).path))
    }

    @Test func aClosedBankAnswersNothing() async throws {
        let bank = LocalBank(store: try LocalStore.inMemory())
        bank.close()
        let client = QBankClient(configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: bank, sessionStore: InMemorySessionStore(StoredSession(token: "t")))
        await #expect(throws: QBankError.self) {
            _ = try await client.catalog()
        }
    }
}
