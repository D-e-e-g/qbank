import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// Linking Sign in with Apple to a signed-in account with a password, as the kit sends and keeps it
/// (`POST /api/me/apple`), and the account's ways in (`signInWith`) that say whether it has. The
/// answers are shaped by the pinned contract's `Account` and `Error` schemas; there is no recording of
/// this route, since only a real Apple token gets past it. Invented data only.
@Suite("Linking Sign in with Apple")
struct AppleLinkTests {
    private static let request = AppleLinkRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "cd", count: 32), password: "synthetic-pass-1")
    private static let account = Account(id: "u-invited", email: "student@example.com", name: "Sam Student", role: .student, mustChangePassword: false)
    private static let linked =
        #"{"id":"u-invited","email":"student@example.com","name":"Sam Student","role":"student","mustChangePassword":false,"palette":"slate","origin":"invited","cloud":{"active":true,"expiresAt":null},"signInWith":["password","apple"]}"#

    private func client(_ transport: FixtureTransport, stored: StoredSession?) -> (QBankClient, InMemorySessionStore) {
        let store = InMemorySessionStore(stored)
        return (QBankClient(configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: transport, sessionStore: store), store)
    }

    private static func pinnedSchema(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        let spec = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return try #require(spec["components"]?["schemas"]?[name])
    }

    // MARK: Linking

    @Test func aLinkSendsTheTokenNonceAndPasswordWithTheSessionAndKeepsTheLinkedAccount() async throws {
        let transport = FixtureTransport(status: 200, body: Self.linked)
        let stored = StoredSession(token: "synthetic-session-token", expiresAt: Date(timeIntervalSince1970: 1_900_000_000), account: Self.account)
        let (client, store) = client(transport, stored: stored)
        let account = try await client.linkApple(Self.request)

        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/api/me/apple")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        #expect(body == .object(["identityToken": .string("synthetic.apple.token"), "nonce": .string(Self.request.nonce), "password": .string("synthetic-pass-1")]))

        #expect(account.signInWith == [.password, .apple])
        #expect(account.signsInWithApple && account.hasPassword)
        #expect(account.origin == .invited, "linking leaves the account an invited one, its bank on the server")
        let kept = try #require(try store.load())
        #expect(kept == StoredSession(token: "synthetic-session-token", expiresAt: stored.expiresAt, account: account), "only the account changed")
    }

    /// The pinned `AppleLink` is `AppleSignIn`'s fields and the password, and the kit sends exactly those.
    @Test func theBodyHasExactlyThePinnedContractsFields() throws {
        let link = try Self.pinnedSchema("AppleLink")
        let parts = try #require(link["allOf"]?.arrayValue)
        var fields: Set<String> = []
        var required: Set<String> = []
        for part in parts {
            let schema = try part["$ref"]?.stringValue.map { try Self.pinnedSchema(String($0.split(separator: "/").last ?? "")) } ?? part
            fields.formUnion(Self.keys(of: schema["properties"]))
            required.formUnion(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        let sent = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Self.request))
        #expect(Self.keys(of: sent) == fields)
        #expect(required == fields)
    }

    private static func keys(of value: JSONValue?) -> Set<String> {
        guard case .object(let object)? = value else { return [] }
        return Set(object.keys)
    }

    @Test(arguments: [
        (401, "invalid_credentials", "That password is not right."),
        (401, "invalid_apple_token", "Apple did not confirm this sign-in."),
        (409, "apple_linked_elsewhere", "This Apple Account is already used by another QBank account."),
        (409, "apple_already_linked", "This QBank account already uses another Apple Account. Unlink it first."),
        (503, "apple_sign_in_unavailable", "Sign in with Apple is not available yet."),
    ])
    func aRefusalLinksNothingAndKeepsTheSessionAsItWas(status: Int, code: String, message: String) async throws {
        let transport = FixtureTransport(status: status, body: #"{"error":"\#(code)","message":"\#(message)"}"#)
        let stored = StoredSession(token: "synthetic-session-token", account: Self.account)
        let (client, store) = client(transport, stored: stored)
        let error = await #expect(throws: QBankError.self) {
            try await client.linkApple(Self.request)
        }
        #expect(error?.serverCode?.rawValue == code)
        #expect(error?.needsSignIn == false, "a refusal never signs anyone out")
        #expect(try store.load() == stored)
    }

    @Test func aLockSaysHowLong() async throws {
        let transport = FixtureTransport(
            status: 429, body: #"{"error":"too_many_attempts","message":"Too many tries.","retryAfterSeconds":840}"#, headers: ["retry-after": "840"])
        let (client, _) = client(transport, stored: StoredSession(token: "synthetic-session-token", account: Self.account))
        let error = await #expect(throws: QBankError.self) {
            try await client.linkApple(Self.request)
        }
        guard case .server(let server)? = error else {
            Issue.record("expected the server's refusal, got \(String(describing: error))")
            return
        }
        #expect(server.retryAfterSeconds == 840)
    }

    @Test func anEndedSessionNeedsSignIn() async throws {
        let transport = FixtureTransport(status: 401, body: #"{"error":"unauthenticated","message":"Sign in to continue."}"#)
        let (client, _) = client(transport, stored: StoredSession(token: "synthetic-session-token", account: Self.account))
        let error = await #expect(throws: QBankError.self) {
            try await client.linkApple(Self.request)
        }
        #expect(error?.needsSignIn == true)
    }

    /// Answers the link as the server would, after `meanwhile` changed what the phone keeps while the
    /// request was on its way.
    private struct Meanwhile: HTTPTransport {
        let store: InMemorySessionStore
        let meanwhile: @Sendable (InMemorySessionStore) throws -> Void

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try meanwhile(store)
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(AppleLinkTests.linked.utf8), response)
        }
    }

    @Test func anAnswerAfterTheSessionChangedIsNotKept() async throws {
        let other = StoredSession(token: "synthetic-other-session", account: Account(id: "u-other", email: "o", name: "o", role: .student, mustChangePassword: false))
        let changes: [(@Sendable (InMemorySessionStore) throws -> Void, StoredSession?)] = [
            ({ try $0.clear() }, nil),
            ({ try $0.save(other) }, other),
        ]
        for (change, expected) in changes {
            let store = InMemorySessionStore(StoredSession(token: "synthetic-session-token", account: Self.account))
            let client = QBankClient(
                configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: Meanwhile(store: store, meanwhile: change), sessionStore: store)
            _ = try await client.linkApple(Self.request)
            #expect(try store.load() == expected, "a sign-out, or another account's sign-in, on the way stays as it is")
        }
    }

    // MARK: Ways in

    @Test(
        "The ways in are read as the server sends them, and one this version does not know is left out",
        arguments: [
            (#"["password"]"#, [Account.SignInMethod.password]),
            (#"["password","apple"]"#, [.password, .apple]),
            (#"["password","passkey","apple"]"#, [.password, .passkey, .apple]),
            (#"["apple"]"#, [.apple]),
            (#"["password","magic-link"]"#, [.password]),
            ("[]", []),
        ])
    func waysIn(json: String, ways: [Account.SignInMethod]) throws {
        let body = #"{"id":"a1","email":"e","name":"n","role":"student","mustChangePassword":false,"origin":"invited","signInWith":\#(json)}"#
        #expect(try QBankJSON.decoder.decode(Account.self, from: Data(body.utf8)).signInWith == ways)
    }

    /// A session kept before ways in, or a server from then: an invited account had its password only,
    /// and a store account Sign in with Apple only.
    @Test(arguments: [("", [Account.SignInMethod.password]), (#","origin":"invited""#, [.password]), (#","origin":"store""#, [.apple])])
    func noWaysInReadAsTheOriginsOwn(field: String, ways: [Account.SignInMethod]) throws {
        let body = #"{"id":"a1","email":"e","name":"n","role":"student","mustChangePassword":false\#(field)}"#
        let account = try QBankJSON.decoder.decode(Account.self, from: Data(body.utf8))
        #expect(account.signInWith == ways)
        #expect(account.hasPassword == (ways == [.password]))
        #expect(!account.signsInWithApple || ways == [.apple])
    }

    @Test func theKeptSessionKeepsTheWaysIn() throws {
        let linked = try QBankJSON.decoder.decode(Account.self, from: Data(Self.linked.utf8))
        let session = StoredSession(token: "t", account: linked)
        let data = try QBankJSON.encoder.encode(session)
        #expect(try QBankJSON.decoder.decode(StoredSession.self, from: data).account?.signInWith == [.password, .apple])
    }

    /// The pinned contract's names for the ways in are the kit's.
    @Test func theWaysInAreThePinnedContracts() throws {
        let method = try Self.pinnedSchema("SignInMethod")
        let names = try #require(method["enum"]?.arrayValue).compactMap(\.stringValue)
        #expect(Set(names) == Set([Account.SignInMethod.password, .passkey, .apple].map(\.rawValue)))
    }
}
