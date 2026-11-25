import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing

@testable import QBankKit

/// Sign in with Apple as the kit sends and keeps it: the nonce, `POST /api/sign-in/apple`, and a sign-in
/// Apple confirmed while the server could not be reached. The answers are shaped by the pinned
/// contract's `SignedIn` and `Error` schemas; there is no recording of this route, since only a real
/// Apple token gets past it. Invented data only.
@Suite("Sign in with Apple")
struct AppleSignInTests {
    /// Answers each "METHOD /path" from a table, and keeps every request.
    private final class Answers: HTTPTransport {
        private let table: [String: (Int, String)]
        private let seen = Mutex<[URLRequest]>([])

        init(_ table: [String: (Int, String)]) { self.table = table }

        var requests: [URLRequest] { seen.withLock { $0 } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            seen.withLock { $0.append(request) }
            let url = try #require(request.url)
            guard let (status, body) = table["\(request.httpMethod ?? "GET") \(url.path)"] else { throw URLError(.cannotConnectToHost) }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    private static let appleUser = "001234.0a1b2c3d4e5f60718293a4b5c6d7e8f9.0123"
    private static let request = AppleSignInRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "ab", count: 32))
    private static let storeAccount =
        #"{"id":"u-store","email":"person@privaterelay.appleid.com","name":"person","role":"student","mustChangePassword":false,"palette":"dusk","origin":"store","cloud":{"active":false,"expiresAt":null},"signInWith":["apple"]}"#
    private static let signedIn = #"{"token":"synthetic-apple-session","user":\#(storeAccount),"expiresAt":"2027-11-24T00:00:00.000Z"}"#

    private func client(_ transport: any HTTPTransport, stored: StoredSession? = nil) -> (QBankClient, InMemorySessionStore) {
        let store = InMemorySessionStore(stored)
        return (QBankClient(configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: transport, sessionStore: store), store)
    }

    // MARK: The nonce

    @Test func aNonceIs64LowercaseHexDigitsAndNeverTheSameTwice() {
        let first = AppleSignInNonce()
        let second = AppleSignInNonce()
        #expect(first.value.count == 64)
        #expect(first.value.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(first != second)
    }

    @Test func appleIsAskedWithTheNoncesSHA256InLowercaseHex() {
        // FIPS 180-4's own example, "abc".
        #expect(AppleSignInNonce(value: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleSignInNonce(bytes: [0x00, 0xff, 0x10]).value == "00ff10")
    }

    // MARK: Signing in

    @Test(arguments: [200, 201])
    func aSignInSendsTheTokenAndNonceAndKeepsTheSessionWithApplesID(status: Int) async throws {
        let transport = Answers(["POST /api/sign-in/apple": (status, Self.signedIn)])
        let (client, store) = client(transport)
        let signedIn = try await client.signInWithApple(Self.request, appleUser: Self.appleUser)

        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/api/sign-in/apple")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        #expect(body == .object(["identityToken": .string("synthetic.apple.token"), "nonce": .string(Self.request.nonce)]))

        #expect(signedIn.user.origin == .store)
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-apple-session")
        #expect(stored.account == signedIn.user)
        #expect(stored.appleUser == Self.appleUser)
        #expect(stored.unsent == nil)
        #expect(!stored.awaitsServer)
    }

    @Test func aRefusalKeepsNothingNewAndLeavesTheStoredSessionAsItWas() async throws {
        let waiting = StoredSession(token: "", account: nil, appleUser: Self.appleUser, unsent: Self.request)
        let message = "This email already has a QBank account with a password. Sign in with your email and password instead."
        let transport = Answers(["POST /api/sign-in/apple": (409, #"{"error":"password_account","message":"\#(message)"}"#)])
        let (client, store) = client(transport, stored: waiting)
        let error = await #expect(throws: QBankError.self) {
            try await client.signInWithApple(Self.request, appleUser: Self.appleUser)
        }
        #expect(error?.serverCode == "password_account")
        #expect(error?.needsSignIn == false)
        #expect(try store.load() == waiting)
    }

    // MARK: Waiting for the server

    @Test func aSignInTheServerHasNotAnsweredIsKeptWithNoToken() throws {
        let (client, store) = client(Answers([:]))
        let account = Account(id: Self.appleUser, email: "", name: "", role: .student, mustChangePassword: false, origin: .store)
        try client.keepAppleSignInForServer(Self.request, account: account, appleUser: Self.appleUser)
        let stored = try #require(try store.load())
        #expect(stored.awaitsServer)
        #expect(stored.account == account)
        #expect(stored.appleUser == Self.appleUser)
        #expect(stored.unsent == Self.request)
    }

    @Test func withNoSessionOnTheServerTheBankAnswersAndTheAccountsRequestsNeverLeaveThePhone() async throws {
        let bank = Answers(["GET /api/semesters": (200, #"{"semesters":[],"topics":[]}"#)])
        let network = Answers(["PUT /api/me/palette": (200, Self.storeAccount)])
        let waiting = StoredSession(token: "", account: nil, appleUser: Self.appleUser, unsent: Self.request)
        let (server, _) = client(network, stored: waiting)
        let phone = server.routingBankWithoutServer(to: bank)

        let catalog = try await phone.catalog()
        #expect(catalog.semesters.isEmpty)
        #expect(bank.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "no token is sent while there is none")

        let error = await #expect(throws: QBankError.self) { try await phone.setPalette(.slate) }
        #expect(error == .transport(.userAuthenticationRequired))
        #expect(error?.needsSignIn == false)
        #expect(network.requests.isEmpty, "nothing of the account reaches the network")
    }

    @Test func sentAgainTheSignInTakesThePlaceOfTheKeptOne() async throws {
        let transport = Answers(["POST /api/sign-in/apple": (200, Self.signedIn)])
        let waiting = StoredSession(token: "", account: nil, appleUser: Self.appleUser, unsent: Self.request)
        let (client, store) = client(transport, stored: waiting)
        let signedIn = try #require(try await client.sendAppleSignInAgain(waiting))
        #expect(signedIn.user.origin == .store)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.httpBody))
        #expect(body == .object(["identityToken": .string(Self.request.identityToken), "nonce": .string(Self.request.nonce)]))
        #expect(try store.load() == StoredSession(token: "synthetic-apple-session", expiresAt: signedIn.expiresAt, account: signedIn.user, appleUser: Self.appleUser))
    }

    @Test func sentAgainAfterASignOutTheAnswerIsNotKept() async throws {
        let transport = Answers(["POST /api/sign-in/apple": (200, Self.signedIn)])
        let waiting = StoredSession(token: "", account: nil, appleUser: Self.appleUser, unsent: Self.request)
        let (client, store) = client(transport)
        #expect(try await client.sendAppleSignInAgain(waiting) == nil)
        #expect(try store.load() == nil, "a sign-out on the way stays a sign-out")

        let other = StoredSession(token: "synthetic-other-session", account: nil)
        try store.save(other)
        #expect(try await client.sendAppleSignInAgain(waiting) == nil)
        #expect(try store.load() == other, "another sign-in on the way stays")
    }

    @Test func aRefusedSignInIsForgottenAndTheRestIsKept() throws {
        let waiting = StoredSession(token: "", account: nil, appleUser: Self.appleUser, unsent: Self.request)
        let (client, store) = client(Answers([:]), stored: waiting)
        try client.forgetUnsentAppleSignIn(waiting)
        let kept = try #require(try store.load())
        #expect(kept.unsent == nil)
        #expect(kept.awaitsServer)
        #expect(kept.appleUser == Self.appleUser)

        let other = StoredSession(token: "synthetic-other-session", account: nil)
        try store.save(other)
        try client.forgetUnsentAppleSignIn(waiting)
        #expect(try store.load() == other)
    }

    @Test func aSessionCheckKeepsApplesIDOfThePerson() async throws {
        let transport = Answers(["GET /api/session": (200, #"{"user":\#(Self.storeAccount),"expiresAt":"2027-12-24T00:00:00.000Z"}"#)])
        let stored = StoredSession(token: "synthetic-apple-session", account: nil, appleUser: Self.appleUser)
        let (client, store) = client(transport, stored: stored)
        _ = try await client.session()
        let refreshed = try #require(try store.load())
        #expect(refreshed.appleUser == Self.appleUser)
        #expect(refreshed.account?.origin == .store)
    }

    @Test func pickingAColorKeepsApplesIDOfThePerson() async throws {
        let transport = Answers(["PUT /api/me/palette": (200, Self.storeAccount)])
        let stored = StoredSession(token: "synthetic-apple-session", account: nil, appleUser: Self.appleUser)
        let (client, store) = client(transport, stored: stored)
        _ = try await client.setPalette(.slate)
        let saved = try #require(try store.load())
        #expect(saved.appleUser == Self.appleUser)
        #expect(saved.token == "synthetic-apple-session")
        #expect(saved.account?.origin == .store)
    }

    // MARK: What the phone kept before

    @Test func aSessionKeptBeforeSignInWithAppleIsAnInvitedAccountsSignedInSession() throws {
        let older = #"{"token":"t","expiresAt":"2027-01-01T00:00:00.000Z","account":{"id":"a1","email":"e","name":"n","role":"student","mustChangePassword":false,"palette":"slate"}}"#
        let stored = try QBankJSON.decoder.decode(StoredSession.self, from: Data(older.utf8))
        #expect(stored.token == "t")
        #expect(!stored.awaitsServer)
        #expect(stored.appleUser == nil)
        #expect(stored.unsent == nil)
        #expect(stored.account?.origin == .invited)
        #expect(stored.account?.palette == .slate)
    }

    /// The account's JSON tail with an origin or none, and the origin read from it.
    static let originFields: [(String, Account.Origin)] = [
        (#","origin":"store""#, .store), (#","origin":"invited""#, .invited), ("", .invited), (#","origin":"partner""#, .invited),
    ]

    @Test("An origin is read as the server sends it; none, or one this version does not know, is invited", arguments: originFields)
    func origins(field: String, origin: Account.Origin) throws {
        let json = #"{"id":"a1","email":"e","name":"n","role":"student","mustChangePassword":false\#(field)}"#
        #expect(try QBankJSON.decoder.decode(Account.self, from: Data(json.utf8)).origin == origin)
    }

    @Test func aWaitingSessionComesBackFromTheKeychainsBytesAsItWent() throws {
        let account = Account(id: Self.appleUser, email: "person@privaterelay.appleid.com", name: "", role: .student, mustChangePassword: false, origin: .store)
        let waiting = StoredSession(token: "", account: account, appleUser: Self.appleUser, unsent: Self.request)
        let data = try QBankJSON.encoder.encode(waiting)
        #expect(try QBankJSON.decoder.decode(StoredSession.self, from: data) == waiting)
    }
}
