import Foundation
import QBankKit
import Testing
import UIKit
@testable import QBank

/// Settings' Sign in with Apple for an account with a password: who is offered it, what linking sends
/// and leaves, and the plain words for every refusal the pinned contract documents. Apple is a
/// stand-in and the server a stub with the contract's shapes, or the Debug fake server. Invented data
/// only.
@MainActor
struct LinkAppleModelTests {
    /// A clock the test moves on by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// Apple's sheet ending without a yes.
    private final class AppleSaysNo: AppleSignInProvider {
        let failure: AppleSignInFailure

        init(_ failure: AppleSignInFailure) {
            self.failure = failure
        }

        func signIn(hashedNonce: String, over window: UIWindow?) async throws(AppleSignInFailure) -> AppleCredential {
            throw failure
        }
    }

    private static let route = "POST /api/me/apple"
    /// The student's account as `POST /api/me/apple` answers it once linked.
    private static let linkedBody =
        #"{"id":"a1","email":"student@example.com","name":"Sam Student","role":"student","mustChangePassword":false,"palette":"dusk","origin":"invited","cloud":{"active":true,"expiresAt":null},"signInWith":["password","apple"]}"#
    private static let linked = Account(
        id: "a1", email: "student@example.com", name: "Sam Student", role: .student, mustChangePassword: false, signInWith: [.password, .apple],
        cloud: Account.Cloud(active: true, expiresAt: nil))

    private func model(
        _ server: StubServer, apple: any AppleSignInProvider = AppleSignInTests.Apple(), clock: Clock = Clock()
    ) -> (LinkAppleModel, AppModel, InMemorySessionStore) {
        let (app, store) = TestApp.make(server, account: .student(), apple: apple)
        let model = LinkAppleModel(app: app) { clock.now }
        model.password = "synthetic-pass-1"
        return (model, app, store)
    }

    // MARK: Who is offered it

    @Test func onlyAnAccountWithAPasswordIsOfferedIt() {
        #expect(LinkAppleModel.isOffered(to: .student(), kind: .invited))
        #expect(LinkAppleModel.isOffered(to: Self.linked, kind: .invited), "a linked account still sees the row, which says so")
        #expect(LinkAppleModel.isOffered(to: .admin, kind: .invited))
        #expect(!LinkAppleModel.isOffered(to: .store(), kind: .free), "a store account signs in with Apple and has no password")
        #expect(!LinkAppleModel.isOffered(to: .store(), kind: .store))
        #expect(!LinkAppleModel.isOffered(to: nil, kind: .invited))
    }

    // MARK: Linking

    @Test func aLinkSendsApplesTokenTheNonceAndHerPasswordAndKeepsHerSignedIn() async throws {
        let server = StubServer([Self.route: .ok(Self.linkedBody)])
        let apple = AppleSignInTests.Apple(user: "000222.testapple0000000000000000000002.0002", email: "student@example.com")
        let (model, app, store) = model(server, apple: apple)
        #expect(!model.isLinked)
        await model.link(over: nil)

        #expect(model.problem == nil)
        #expect(model.isLinked)
        #expect(model.password.isEmpty, "her password is not kept once it is used")
        #expect(app.route == .signedIn(Self.linked))
        #expect(app.kind == .invited, "her bank stays on the server")
        #expect(server.calls == [Self.route], "nothing else is asked of the server")
        let stored = try #require(try store.load())
        #expect(stored.token == TestApp.token, "she stays signed in with the same session")
        #expect(stored.account == Self.linked)

        let body = try #require(server.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(Set(sent.keys) == ["identityToken", "nonce", "password"])
        #expect(sent["identityToken"] == "synthetic.apple.token")
        #expect(sent["password"] == "synthetic-pass-1")
        #expect(apple.asked == [AppleSignInNonce(value: try #require(sent["nonce"])).hashed], "Apple was asked with the hash of the nonce sent")
        #expect(server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestApp.token)")
    }

    @Test func noPasswordIsAskedForBeforeApple() async {
        let server = StubServer()
        let apple = AppleSignInTests.Apple()
        let (model, _, _) = model(server, apple: apple)
        model.password = ""
        await model.link(over: nil)
        #expect(model.problem == LinkAppleWording.noPassword)
        #expect(apple.asked.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test func closingApplesSheetSaysNothingAndSendsNothing() async {
        let server = StubServer()
        let (model, _, _) = model(server, apple: AppleSaysNo(.canceled))
        await model.link(over: nil)
        #expect(model.problem == nil)
        #expect(model.password == "synthetic-pass-1", "her password stays for the next try")
        #expect(server.requests.isEmpty)
    }

    @Test func appleNotFinishingSaysSo() async {
        let server = StubServer()
        let (model, _, _) = model(server, apple: AppleSaysNo(.failed))
        await model.link(over: nil)
        #expect(model.problem == AppleSignInWording.appleDidNotFinish)
        #expect(server.requests.isEmpty)
    }

    // MARK: Refusals

    @Test(arguments: [
        (401, "invalid_credentials", "That password is not right.", "That password is not right, so nothing was linked. Try again.", true),
        (401, "invalid_apple_token", "Apple did not confirm this sign-in.", "Apple did not confirm this sign-in, so nothing was linked. Try again.", false),
        (400, "invalid_request", "Check the fields and try again.", "Sign in with Apple did not finish. Try again.", false),
        (
            409, "apple_linked_elsewhere", "This Apple Account is already used by another QBank account.",
            "This Apple Account already signs in to another QBank account, so it cannot be linked to this one. Nothing was linked. Try a different Apple Account, or keep signing in with your email and password.",
            false
        ),
        (502, "apple_unreachable", "Apple's keys could not be read.", "QBank could not check this sign-in with Apple, so nothing was linked. Try again in a moment.", false),
        (
            503, "apple_sign_in_unavailable", "Sign in with Apple is not available yet.",
            "Sign in with Apple is not available on QBank's server yet, so nothing was linked. Try again later. Your email and password keep working.", false
        ),
        (
            503, "auth_unavailable", "Sign-in is not available right now.",
            "QBank's server cannot link Sign in with Apple right now. Try again later. Your email and password keep working.", false
        ),
    ])
    func aRefusalLinksNothingKeepsHerSignedInAndSaysWhatToDo(status: Int, code: String, message: String, said: String, clearsPassword: Bool) async throws {
        let server = StubServer([Self.route: .error(status, code, message)])
        let (model, app, store) = model(server)
        await model.link(over: nil)
        #expect(model.problem == said)
        #expect(model.problem != message, "Settings says it in its own words")
        #expect(model.password.isEmpty == clearsPassword)
        #expect(!model.isLinked)
        #expect(model.canLink, "she can try again")
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load()?.token == TestApp.token)
    }

    @Test func anIdentityAnotherAccountHasIsRefusedInPlainWords() async {
        let server = StubServer([Self.route: .error(409, "apple_linked_elsewhere", "This Apple Account is already used by another QBank account.")])
        let (model, _, _) = model(server)
        await model.link(over: nil)
        #expect(
            model.problem
                == "This Apple Account already signs in to another QBank account, so it cannot be linked to this one. Nothing was linked. Try a different Apple Account, or keep signing in with your email and password."
        )
    }

    /// Her account has another Apple identity this phone did not know of: the phone asks the server
    /// again, so Settings shows Sign in with Apple as linked.
    @Test func anotherIdentityAlreadyLinkedIsLearnedFromTheServer() async throws {
        let server = StubServer([
            Self.route: .error(409, "apple_already_linked", "This QBank account already uses another Apple Account. Unlink it first."),
            "GET /api/session": .ok(#"{"user":\#(Self.linkedBody),"expiresAt":"2027-01-01T00:00:00.000Z"}"#),
        ])
        let (model, app, _) = model(server)
        await model.link(over: nil)
        #expect(
            model.problem
                == "Your QBank account is already linked to a different Apple Account. Use that Apple Account to sign in with Apple, or keep signing in with your email and password."
        )
        #expect(server.calls == [Self.route, "GET /api/session"])
        #expect(app.account?.signsInWithApple == true)
        #expect(model.isLinked)
    }

    /// Too many wrong passwords or refused tokens: linking waits until the lock's time has passed.
    @Test func aLockWaitsForItsTime() async {
        let clock = Clock()
        let locked = StubServer.Reply(
            status: 429,
            body: #"{"error":"too_many_attempts","message":"Too many tries. Try again in 14 minutes.","retryAfterSeconds":840}"#,
            headers: ["retry-after": "840"]
        )
        let server = StubServer([Self.route: locked])
        let apple = AppleSignInTests.Apple()
        let (model, _, _) = model(server, apple: apple, clock: clock)
        await model.link(over: nil)
        #expect(model.problem == "Too many tries. Nothing was linked. Try again in 14 minutes.")
        #expect(model.lockedUntil == clock.now.addingTimeInterval(840))
        #expect(!model.canLink)
        #expect(model.password.isEmpty)

        model.password = "synthetic-pass-1"
        await model.link(over: nil)
        #expect(apple.asked.count == 1, "Apple is not asked while locked")
        #expect(server.calls == [Self.route])

        clock.now += 839
        model.lockEnded()
        #expect(!model.canLink)
        clock.now += 1
        model.lockEnded()
        #expect(model.canLink)
        #expect(model.problem == nil)
    }

    @Test func anEndedSessionSignsHerOut() async {
        let server = StubServer([Self.route: .error(401, "unauthenticated", "Sign in to continue.")])
        let (model, app, _) = model(server)
        await model.link(over: nil)
        #expect(app.route == .signedOut)
        #expect(model.problem == nil)
    }

    @Test func aTemporaryPasswordLeadsToChoosingANewOne() async {
        let server = StubServer([Self.route: .error(403, "must_change_password", "Choose a new password to continue.")])
        let (model, app, _) = model(server)
        await model.link(over: nil)
        #expect(app.route == .choosingPassword(.student()))
        #expect(model.problem == nil)
    }

    @Test func noSignalIsSaidPlainlyAndLinksNothing() async {
        let (model, app, _) = model(StubServer([Self.route: .offline]))
        await model.link(over: nil)
        #expect(model.problem == "No connection. Check Wi-Fi or cellular data and try again.")
        #expect(model.password == "synthetic-pass-1")
        #expect(app.route == .signedIn(.student()))
    }

    /// Every refusal code the pinned contract documents for `POST /api/me/apple` is said in Settings'
    /// own words, or is one the app handles everywhere: an ended session, or a temporary password. A
    /// contract that documents a new one fails here until it has its words.
    @Test func everyRefusalThePinnedContractDocumentsHasItsOwnWords() throws {
        let spec = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/QBankKit/Tests/QBankKitTests/Fixtures/openapi.json")
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: spec)) as? [String: Any])
        let paths = try #require(document["paths"] as? [String: Any])
        let link = try #require((paths["/api/me/apple"] as? [String: Any])?["post"] as? [String: Any])
        let responses = try #require(link["responses"] as? [String: [String: Any]])
        var codes: [(Int, String)] = []
        for (status, response) in responses {
            guard let status = Int(status), status >= 400, let description = response["description"] as? String else { continue }
            for match in description.matches(of: /`([a-z_]+)`/) {
                codes.append((status, String(match.output.1)))
            }
        }
        let handledEverywhere: Set<String> = ["unauthenticated", "must_change_password"]
        #expect(Set(codes.map(\.1)).isSuperset(of: ["invalid_credentials", "invalid_apple_token", "apple_linked_elsewhere", "apple_already_linked", "too_many_attempts"]))
        for (status, code) in codes where !handledEverywhere.contains(code) {
            let error = QBankError.server(ServerError(status: status, code: .init(rawValue: code), message: "The server's own words."))
            let words = LinkAppleWording.problem(error)
            #expect(words != "The server's own words.", "\(code) has no words of its own")
        }
    }
}

/// The Debug fake server's `POST /api/me/apple`, called as raw requests: it links as the real route
/// does, and Sign in with Apple then opens the same account. The UI tests rely on it.
struct FakeServerAppleLinkTests {
    private static let person = "005000.fakeapple0000000000000000000005.0005"

    private func link(_ calls: FakeServerRoutesTests.Calls, user: String = person, password: String = FakeQBankServer.student.password) async throws
        -> FakeServerRoutesTests.Answer
    {
        let nonce = AppleSignInNonce()
        let token = FakeQBankServer.appleToken(user: user, email: FakeQBankServer.student.email, hashedNonce: nonce.hashed)
        return try await calls.call("POST", "/api/me/apple", ["identityToken": token, "nonce": nonce.value, "password": password])
    }

    @Test func aLinkedAccountSignsInWithAppleToTheSameAccount() async throws {
        let calls = FakeServerRoutesTests.Calls()
        let wrong = try await link(calls, password: "not-her-password")
        #expect(wrong.status == 401)
        #expect(wrong.error == "invalid_credentials")

        let linked = try await link(calls)
        #expect(linked.status == 200)
        #expect(linked["id"] as? String == "fake-student")
        #expect(linked["signInWith"] as? [String] == ["password", "apple"])
        #expect(linked["origin"] as? String == "invited")
        #expect(try await link(calls).status == 200, "linking the identity it has changes nothing")

        var signedOut = FakeServerRoutesTests.Calls(calls.server)
        signedOut.token = nil
        let nonce = AppleSignInNonce()
        let token = FakeQBankServer.appleToken(user: Self.person, email: FakeQBankServer.student.email, hashedNonce: nonce.hashed)
        let signedIn = try await signedOut.call("POST", "/api/sign-in/apple", ["identityToken": token, "nonce": nonce.value])
        #expect(signedIn.status == 200)
        #expect((signedIn["user"] as? [String: Any])?["id"] as? String == "fake-student", "the same account, with the same content")
    }

    @Test func anIdentityIsOneAccountsAndAnAccountHasOne() async throws {
        let calls = FakeServerRoutesTests.Calls()
        let elsewhere = try await link(calls, user: FakeQBankServer.applePerson.user)
        #expect(elsewhere.status == 409)
        #expect(elsewhere.error == "apple_linked_elsewhere")

        #expect(try await link(calls).status == 200)
        let another = try await link(calls, user: "006000.fakeapple0000000000000000000006.0006")
        #expect(another.status == 409)
        #expect(another.error == "apple_already_linked")
    }

    @Test func aTokenIsTakenOnceAndOnlyWithItsNonce() async throws {
        let calls = FakeServerRoutesTests.Calls()
        let nonce = AppleSignInNonce()
        let token = FakeQBankServer.appleToken(user: Self.person, email: FakeQBankServer.student.email, hashedNonce: nonce.hashed)
        let password = FakeQBankServer.student.password
        let mismatched = try await calls.call("POST", "/api/me/apple", ["identityToken": token, "nonce": AppleSignInNonce().value, "password": password])
        #expect(mismatched.error == "invalid_apple_token")
        #expect(try await calls.call("POST", "/api/me/apple", ["identityToken": token, "nonce": nonce.value, "password": password]).status == 200)
        let replayed = try await calls.call("POST", "/api/me/apple", ["identityToken": token, "nonce": nonce.value, "password": password])
        #expect(replayed.status == 401)
        #expect(replayed.error == "invalid_apple_token")
    }
}
