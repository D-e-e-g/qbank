import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Contract: sign-in and session")
struct SessionContractTests {
    @Test func health() async throws {
        let transport = try FixtureTransport("health")
        let (client, _) = TestClient.make(transport, token: nil)
        let health = try await client.health()
        #expect(health.status == "ok")
        try expectRequest(transport.requests.first, matches: Fixture.load("health"))
    }

    @Test func signInStoresTheBearerToken() async throws {
        let transport = try FixtureTransport("sign-in")
        let (client, store) = TestClient.make(transport, token: nil)
        let signedIn = try await client.signIn(email: "student@example.com", password: "synthetic-pass-1")
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-in"))
        #expect(signedIn.token == "synthetic-session-token")
        #expect(signedIn.user.role == .student)
        #expect(signedIn.user.mustChangePassword == false)
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == signedIn.user)
        #expect(stored.expiresAt == signedIn.expiresAt)
    }

    @Test func wrongPasswordStoresNothing() async throws {
        let transport = try FixtureTransport("sign-in-wrong-password")
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signIn(email: "student@example.com", password: "not-the-password")
        }
        #expect(error?.serverCode == .invalidCredentials)
        #expect(error?.needsSignIn == false)
        #expect(try store.load() == nil)
    }

    @Test func lockedSignInSaysHowLong() async throws {
        let transport = try FixtureTransport("sign-in-locked")
        let (client, _) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signIn(email: "locked@example.com", password: "wrong")
        }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 429)
        #expect(server.code == .tooManyAttempts)
        #expect(server.retryAfterSeconds == 900)
        #expect(error?.isTemporary == true)
    }

    @Test func signUpMakesASignedInUserAccount() async throws {
        let transport = try FixtureTransport("sign-up")
        let (client, store) = TestClient.make(transport, token: nil)
        let signedIn = try await client.signUp(email: "new.user@example.com", password: "synthetic-pass-2")
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-up"))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(signedIn.token == "synthetic-session-token")
        #expect(signedIn.user.email == "new.user@example.com")
        #expect(signedIn.user.role == .student)
        #expect(signedIn.user.mustChangePassword == false)
        #expect(signedIn.user.palette == .dusk)
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == signedIn.user)
        #expect(stored.expiresAt == signedIn.expiresAt)
    }

    @Test func refusedSignUpStoresNothing() async throws {
        let transport = try FixtureTransport("sign-up-refused")
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signUp(email: "stranger@example.com", password: "synthetic-pass-3")
        }
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-up-refused"))
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 403)
        #expect(server.code == .signUpRefused)
        #expect(server.message == "This email can't sign up here. If you already have an account, sign in. Otherwise, ask the owner to add your email.")
        #expect(error?.needsSignIn == false)
        #expect(try store.load() == nil)
    }

    @Test func lockedSignUpSaysHowLong() async throws {
        let transport = try FixtureTransport("sign-up-locked")
        let (client, _) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signUp(email: "locked@example.com", password: "synthetic-pass-3")
        }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 429)
        #expect(server.code == .tooManyAttempts)
        #expect(server.retryAfterSeconds == 900)
        #expect(server.message == "Too many tries. Try again in 15 minutes.")
    }

    @Test func shortSignUpPasswordIsRefused() async throws {
        let transport = try FixtureTransport("sign-up-short-password")
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signUp(email: "new.user@example.com", password: "short")
        }
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-up-short-password"))
        #expect(error?.serverCode == .invalidRequest)
        #expect(try store.load() == nil)
    }

    @Test func sessionRefreshesTheStoredAccount() async throws {
        let transport = try FixtureTransport("session")
        let (client, store) = TestClient.make(transport)
        let session = try await client.session()
        try expectRequest(transport.requests.first, matches: Fixture.load("session"))
        #expect(session.user.email == "student@example.com")
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == session.user)
    }

    @Test func endedSessionNeedsSignIn() async throws {
        let transport = try FixtureTransport("session-after-sign-out")
        let (client, _) = TestClient.make(transport, token: "synthetic-session-token-2")
        let error = await #expect(throws: QBankError.self) { try await client.session() }
        #expect(error?.needsSignIn == true)
        try expectRequest(transport.requests.first, matches: Fixture.load("session-after-sign-out"))
    }

    @Test func changePasswordStoresTheNewToken() async throws {
        let transport = try FixtureTransport("change-password")
        let (client, store) = TestClient.make(transport)
        let signedIn = try await client.changePassword(current: "synthetic-pass-1", new: "synthetic-pass-3")
        try expectRequest(transport.requests.first, matches: Fixture.load("change-password"))
        #expect(signedIn.token == "synthetic-session-token-2")
        #expect(try store.load()?.token == "synthetic-session-token-2")
    }

    @Test func wrongCurrentPasswordKeepsTheSession() async throws {
        let transport = try FixtureTransport("change-password-wrong")
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.changePassword(current: "not-it", new: "synthetic-pass-3")
        }
        #expect(error?.serverCode == .invalidCredentials)
        #expect(error?.needsSignIn == false)
        #expect(try store.load()?.token == "synthetic-session-token")
        try expectRequest(transport.requests.first, matches: Fixture.load("change-password-wrong"))
    }

    @Test(arguments: [
        ("change-password-same", ServerError.Code.samePassword),
        ("change-password-short", ServerError.Code.invalidRequest),
    ])
    func refusedNewPasswordKeepsTheSession(name: String, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, store) = TestClient.make(transport)
        let current = try #require(fixture.request.body?["currentPassword"]?.stringValue)
        let new = try #require(fixture.request.body?["newPassword"]?.stringValue)
        let error = await #expect(throws: QBankError.self) {
            try await client.changePassword(current: current, new: new)
        }
        #expect(error?.serverCode == code)
        #expect(error?.needsSignIn == false)
        #expect(try store.load()?.token == "synthetic-session-token")
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func signOutEndsTheSessionHereAndThere() async throws {
        let transport = try FixtureTransport("sign-out")
        let (client, store) = TestClient.make(transport, token: "synthetic-session-token-2")
        try await client.signOut()
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-out"))
        #expect(try store.load() == nil)
    }

    /// Signed in on two devices, she signs out everywhere from one: it forgets its session, and the
    /// other device's next call needs sign-in.
    @Test func signOutEverywhereEndsEverySession() async throws {
        let transport = try FixtureTransport("sign-out-everywhere")
        let (client, store) = TestClient.make(transport)
        try await client.signOutEverywhere()
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-out-everywhere"))
        #expect(try store.load() == nil)

        let other = try FixtureTransport("session-after-sign-out-everywhere")
        let (laptop, _) = TestClient.make(other, token: "synthetic-session-token-2")
        let error = await #expect(throws: QBankError.self) { try await laptop.session() }
        #expect(error?.needsSignIn == true)
        try expectRequest(other.requests.first, matches: Fixture.load("session-after-sign-out-everywhere"))
    }

    /// From a session that had already ended, the server ends nothing; the session is left for the
    /// app to clear, as any ended one.
    @Test func signOutEverywhereFromAnEndedSessionNeedsSignIn() async throws {
        let transport = try FixtureTransport("sign-out-everywhere-signed-out")
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.signOutEverywhere() }
        #expect(error?.needsSignIn == true)
        #expect(try store.load()?.token == "synthetic-session-token")
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-out-everywhere-signed-out"))
    }

    @Test func pickingAPaletteKeepsTheAccountItReturns() async throws {
        let transport = try FixtureTransport("palette")
        let (client, store) = TestClient.make(transport)
        let account = try await client.setPalette(.slate)
        try expectRequest(transport.requests.first, matches: Fixture.load("palette"))
        #expect(account.palette == .slate)
        #expect(account.email == "student@example.com")
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == account)
    }

    @Test func sessionCarriesThePalette() async throws {
        let transport = try FixtureTransport("session-slate")
        let (client, store) = TestClient.make(transport)
        let session = try await client.session()
        try expectRequest(transport.requests.first, matches: Fixture.load("session-slate"))
        #expect(session.user.palette == .slate)
        #expect(try store.load()?.account?.palette == .slate)
    }

    @Test func sessionFromBeforePalettesIsDusk() async throws {
        let transport = try FixtureTransport("session")
        let (client, _) = TestClient.make(transport)
        #expect(try await client.session().user.palette == .dusk)
    }
}
