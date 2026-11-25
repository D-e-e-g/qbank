import Foundation
import QBankKit
import Testing
import UIKit
@testable import QBank

/// Sign in with Apple in the model: where each answer of the server leaves the person, what the phone
/// keeps while the server cannot answer, and sending it again. Apple is a stand-in and the server a
/// stub with the contract's shapes and words. Invented data only.
@MainActor
struct AppleSignInTests {
    /// Answers in Apple's place, as Apple would after the person agreed, and keeps the nonce hash it
    /// was asked with.
    final class Apple: AppleSignInProvider {
        let credential: AppleCredential
        private(set) var asked: [String] = []

        init(user: String = TestApp.appleUser, email: String? = "person@privaterelay.appleid.com") {
            credential = AppleCredential(user: user, identityToken: "synthetic.apple.token", email: email)
        }

        func signIn(hashedNonce: String, over window: UIWindow?) async throws(AppleSignInFailure) -> AppleCredential {
            asked.append(hashedNonce)
            return credential
        }
    }

    private static let route = "POST /api/sign-in/apple"

    private func signedOut(_ server: StubServer, apple: Apple = Apple(), banks: PhoneBanks = .memory()) -> (AppModel, InMemorySessionStore) {
        TestApp.make(server, apple: apple, banks: banks)
    }

    // MARK: Signed in

    @Test func aStoreAccountOpensItsBankOnThisPhoneUnderApplesID() async throws {
        let server = StubServer([Self.route: Reply(status: 201, body: Bodies.appleSignedIn())])
        let apple = Apple()
        let (app, store) = signedOut(server, apple: apple)
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)

        #expect(model.problem == nil)
        #expect(app.route == .signedIn(.store()))
        #expect(app.kind == .free)
        #expect(!app.awaitsServer)
        #expect(app.phoneKey == TestApp.appleUser)
        #expect(app.offline == nil)
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-apple-token")
        #expect(stored.appleUser == TestApp.appleUser)

        // Apple was asked with the hash of the very nonce the server was sent.
        let body = try #require(server.requests.first?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent["identityToken"] == "synthetic.apple.token")
        #expect(apple.asked == [AppleSignInNonce(value: try #require(sent["nonce"])).hashed])

        let made = try await app.client.createTopic(title: "Pharmacology")
        #expect(try await app.client.catalog().topics.map(\.id) == [made.id])
        #expect(server.calls == [Self.route], "her study stays on the phone")
    }

    @Test func eachSignInAsksWithANewNonce() async throws {
        let server = StubServer([Self.route: .error(401, "invalid_apple_token", "Apple did not confirm this sign-in. Try again.")])
        let apple = Apple()
        let (app, _) = signedOut(server, apple: apple)
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)
        await model.signIn(over: nil)
        #expect(apple.asked.count == 2)
        #expect(Set(apple.asked).count == 2)
    }

    @Test func anAccountTheOwnerSetUpThatLinkedAppleIsOnTheServer() async throws {
        let server = StubServer([Self.route: .ok(Bodies.appleSignedIn(origin: "invited")), "GET /api/semesters": .ok(Bodies.semesters())])
        let (app, _) = signedOut(server)
        await AppleSignInModel(app: app).signIn(over: nil)
        #expect(app.account?.email == "student@example.com")
        #expect(app.kind == .invited)
        #expect(app.offline != nil, "its saved courses and waiting answers are kept as ever")
        _ = try await app.client.catalog()
        #expect(server.calls == [Self.route, "GET /api/semesters"])
    }

    @Test func aNewBankIsGivenTheSampleSetAndAReturningPersonsIsLeftAsItWas() async throws {
        let server = StubServer([Self.route: Reply(status: 201, body: Bodies.appleSignedIn()), "POST /api/sign-out": .ok(#"{"status":"ok"}"#)])
        let source = try #require(SampleSet.bundledSource())
        let defaults = TestApp.freshDefaults()
        let store = InMemorySessionStore()
        let client = QBankClient(configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: server, sessionStore: store)
        let app = AppModel(
            client: client, banks: .memory(), sampleSet: source, appleSignIn: Apple(), look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)), drafts: WriteDraftStore(defaults: defaults), storage: .memory()
        )
        await AppleSignInModel(app: app).signIn(over: nil)
        let topic = try #require(try await app.client.catalog().topics.first)
        #expect(topic.title == SampleSet.topic)
        let renamed = try await app.client.renameTopic(id: topic.id, title: "My topic")

        await app.signOut()
        await AppleSignInModel(app: app).signIn(over: nil)
        #expect(try await app.client.catalog().topics.map(\.title) == [renamed.title], "the same bank, with nothing added")
    }

    // MARK: The server cannot answer

    @Test(arguments: [
        (StubServer.Reply.offline, "No connection. Check Wi-Fi or cellular data and try again."),
        (.error(502, "apple_unreachable", "Apple could not be reached. Try again."), "QBank could not check this sign-in with Apple. Try again in a moment."),
        (.error(502, "auth_failed", "Sign-in failed. Try again."), "QBank could not check this sign-in with Apple. Try again in a moment."),
        (
            .error(503, "apple_sign_in_unavailable", "Sign in with Apple is not available yet."),
            "Sign in with Apple is not available on QBank's server yet. Try again later, or use an existing QBank account."
        ),
        (.error(503, "auth_unavailable", "Sign-in is not available right now."), "QBank's server cannot sign anyone in right now. Try again later."),
    ])
    func whenTheServerCannotAnswerTheBankOpensOnThisPhoneAndTheSignInWaits(reply: StubServer.Reply, said: String) async throws {
        let server = StubServer([Self.route: reply, "PUT /api/me/palette": .ok(Bodies.account(palette: "slate"))])
        let (app, store) = signedOut(server)
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)

        #expect(model.problem == nil)
        #expect(app.kind == .free)
        #expect(app.awaitsServer)
        #expect(app.serverSignInProblem == said)
        #expect(app.account?.origin == .store)
        #expect(app.account?.email == "person@privaterelay.appleid.com")
        #expect(app.phoneKey == TestApp.appleUser)
        let stored = try #require(try store.load())
        #expect(stored.awaitsServer)
        #expect(stored.unsent?.identityToken == "synthetic.apple.token")

        // Her study works on the phone, and nothing of the account goes to a server with no session for it.
        let made = try await app.client.createTopic(title: "Pharmacology")
        #expect(try await app.client.catalog().topics.map(\.id) == [made.id])
        server[Self.route] = reply
        await app.pickPalette(.slate)
        #expect(app.paletteProblem == AppleSignInWording.paletteAwaitsServer)
        #expect(app.palette == .dusk)
        #expect(server.calls.allSatisfy { $0 == Self.route })
    }

    @Test func onceTheServerAnswersTheAccountIsItsAndTheScreensStay() async throws {
        let server = StubServer([Self.route: .offline])
        let (app, store) = signedOut(server)
        await AppleSignInModel(app: app).signIn(over: nil)
        let signIns = app.signIns
        let made = try await app.client.createTopic(title: "Pharmacology")
        var draft = SetDraft()
        draft.title = "Written while waiting"
        app.drafts.keep(draft)

        server[Self.route] = Reply(status: 201, body: Bodies.appleSignedIn())
        await app.sendAppleSignInAgain()

        #expect(!app.awaitsServer)
        #expect(app.serverSignInProblem == nil)
        #expect(app.route == .signedIn(.store()))
        #expect(app.signIns == signIns, "the same person: the screens stay as they are")
        #expect(app.phoneKey == TestApp.appleUser)
        #expect(app.drafts.drafts.map(\.title) == ["Written while waiting"])
        #expect(try store.load()?.token == "synthetic-apple-token")
        #expect(try await app.client.catalog().topics.map(\.id) == [made.id])
    }

    @Test func aSignInKeptAtLaunchIsSentAgain() async throws {
        let server = StubServer([Self.route: Reply(status: 201, body: Bodies.appleSignedIn())])
        let unsent = AppleSignInRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "c", count: 64))
        let (app, _) = TestApp.free(server, awaitsServer: true, unsent: unsent)
        #expect(app.awaitsServer)
        #expect(app.route == .signedIn(.store()), "the bank opens before the server answers")
        await app.refreshSession()
        #expect(!app.awaitsServer)
        let body = try #require(server.requests.first?.httpBody)
        #expect(try JSONDecoder().decode(AppleSignInRequest.self, from: body) == unsent)
    }

    @Test func theNetworkComingBackSendsItAgain() async throws {
        let server = StubServer([Self.route: Reply(status: 201, body: Bodies.appleSignedIn())])
        let connection = Connection(isOnline: false)
        let unsent = AppleSignInRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "c", count: 64))
        let (app, _) = TestApp.free(server, connection: connection, awaitsServer: true, unsent: unsent)
        connection.update(isOnline: true)
        try await waitUntil { !app.awaitsServer }
    }

    @Test(arguments: [
        ("invalid_apple_token", 401, false), ("password_account", 409, false), ("email_in_use", 409, false), ("too_many_attempts", 429, true),
    ])
    func aRefusedResendIsSaidAndOnlyALockedOneIsKept(code: String, status: Int, kept: Bool) async throws {
        let server = StubServer([Self.route: .error(status, code, "Refused.")])
        let unsent = AppleSignInRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "c", count: 64))
        let (app, store) = TestApp.free(server, awaitsServer: true, unsent: unsent)
        await app.sendAppleSignInAgain()
        #expect(app.awaitsServer, "the bank on the phone stays open")
        #expect(app.serverSignInProblem != nil)
        #expect((try store.load()?.unsent != nil) == kept)
        await app.sendAppleSignInAgain()
        #expect(server.calls.count == (kept ? 2 : 1))
    }

    @Test(arguments: [("invalid_apple_token", 401), ("password_account", 409), ("email_in_use", 409)])
    func aRefusedResendAsksForSignInWithAppleAgainAfterARelaunch(code: String, status: Int) async throws {
        let server = StubServer([Self.route: .error(status, code, "Refused.")])
        let unsent = AppleSignInRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "c", count: 64))
        let (app, store) = TestApp.free(server, awaitsServer: true, unsent: unsent)
        #expect(!app.needsAppleSignInAgain, "a kept sign-in is still sent again on its own")
        await app.sendAppleSignInAgain()
        #expect(app.needsAppleSignInAgain)

        let client = QBankClient(configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: server, sessionStore: store)
        let relaunched = AppModel(client: client, appleSignIn: Apple(), storage: .memory())
        #expect(relaunched.route == .signedIn(.store()), "the bank on the phone still opens")
        #expect(relaunched.awaitsServer)
        #expect(relaunched.needsAppleSignInAgain)
        #expect(relaunched.serverSignInProblem == nil)
        await relaunched.refreshSession()
        #expect(server.calls.count == 1, "nothing is sent again on its own")

        server[Self.route] = Reply(status: 201, body: Bodies.appleSignedIn())
        #expect(await relaunched.signInWithApple(Apple().credential, nonce: AppleSignInNonce()) == .signedIn)
        #expect(!relaunched.awaitsServer)
        #expect(!relaunched.needsAppleSignInAgain)
    }

    @Test func settingsSaysOnlyANewSignInWithAppleConnectsAPhoneWhoseKeptOneWasRefused() {
        #expect(AppleSignInWording.awaitsServer.contains("tries again on its own"))
        let wording = AppleSignInWording.needsAppleSignInAgain
        #expect(!wording.contains("tries again on its own"))
        #expect(wording.contains("not connected to the QBank service"))
        #expect(wording.contains("Sign in with Apple again"))
        #expect(wording.contains("use an existing QBank account"))
        #expect(!wording.localizedCaseInsensitiveContains("student"))
    }

    @Test func signingOutWhileWaitingKeepsTheBankAndAsksNoServer() async throws {
        let server = StubServer([Self.route: .offline])
        let (app, store) = signedOut(server)
        await AppleSignInModel(app: app).signIn(over: nil)
        let made = try await app.client.createTopic(title: "Pharmacology")
        try await app.signOutEverywhere()
        #expect(app.route == .signedOut)
        #expect(!app.awaitsServer)
        #expect(try store.load() == nil)
        #expect(server.calls == [Self.route])

        server[Self.route] = Reply(status: 201, body: Bodies.appleSignedIn())
        await AppleSignInModel(app: app).signIn(over: nil)
        #expect(try await app.client.catalog().topics.map(\.id) == [made.id], "the same person finds the bank they left")
    }

    // MARK: Refused

    @Test(arguments: [
        (400, "invalid_request", "Sign in with Apple did not finish. Try again.", nil as String?),
        (401, "invalid_apple_token", "Apple did not confirm this sign-in. Try Sign in with Apple again.", nil),
        (
            409, "password_account", "This email already has a QBank account with a password. Sign in with your email and password instead.",
            "person@privaterelay.appleid.com"
        ),
        (
            409, "email_in_use",
            "This email already belongs to another QBank account. Sign in to that account with its email and password, or use another Apple Account.",
            "person@privaterelay.appleid.com"
        ),
    ])
    func aRefusalSaysWhyAndSignsNoOneIn(status: Int, code: String, said: String, emailDoor: String?) async throws {
        let server = StubServer([Self.route: .error(status, code, "The server's own words.")])
        let (app, store) = signedOut(server)
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)
        #expect(app.route == .signedOut)
        #expect(model.problem == said)
        #expect(model.emailDoor == emailDoor)
        #expect(try store.load() == nil)
        #expect(!model.isSigningIn)
    }

    @Test func aLockSaysHowLongAndPointsToTheEmailDoor() async throws {
        let server = StubServer([Self.route: Reply(status: 429, body: #"{"error":"too_many_attempts","message":"Too many tries. Try again in 15 minutes.","retryAfterSeconds":900}"#)])
        let (app, _) = signedOut(server)
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)
        #expect(model.problem == "Too many tries from this network. Try again in 15 minutes, or use an existing QBank account.")
        #expect(app.route == .signedOut)
    }

    @Test func closingApplesSheetSaysNothingAndAsksNoServer() async throws {
        let server = StubServer()
        let (app, _) = TestApp.make(server, apple: DebugScriptedAppleSignIn(script: .cancel))
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)
        #expect(model.problem == nil)
        #expect(app.route == .signedOut)
        #expect(server.requests.isEmpty)
    }

    @Test func aBankThatCannotOpenSignsNoOneInAndEndsTheServersSession() async throws {
        struct Unopenable: Error {}
        let server = StubServer([Self.route: Reply(status: 201, body: Bodies.appleSignedIn()), "POST /api/sign-out": .ok(#"{"status":"ok"}"#)])
        let (app, store) = signedOut(server, banks: PhoneBanks { _ in throw Unopenable() })
        let model = AppleSignInModel(app: app)
        await model.signIn(over: nil)
        #expect(app.route == .signedOut)
        #expect(model.problem == AppleSignInWording.bankDidNotOpen)
        #expect(server.calls == [Self.route, "POST /api/sign-out"])
        #expect(try store.load() == nil)
    }

    // MARK: Launch

    @Test func aStoreSessionWhoseBankCannotOpenWaitsOnTheFirstScreenAndKeepsTheSession() throws {
        struct Unopenable: Error {}
        let session = StoredSession(token: TestApp.token, account: .store(), appleUser: TestApp.appleUser)
        let store = InMemorySessionStore(session)
        let client = QBankClient(configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: StubServer(), sessionStore: store)
        let app = AppModel(client: client, banks: PhoneBanks { _ in throw Unopenable() }, appleSignIn: Apple(), storage: .memory())
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == AppleSignInWording.bankDidNotOpen)
        #expect(try store.load() == session, "nothing is replaced by an empty bank; signing in again finds it")
    }

    @Test func aSessionKeptBeforeTheUpdateOpensSignedInOnTheServerWithItsWaitingAnswers() async throws {
        let older = #"{"token":"synthetic-test-token","account":{"id":"a1","email":"student@example.com","name":"Sam Student","role":"student","mustChangePassword":false}}"#
        let session = try QBankJSON.decoder.decode(StoredSession.self, from: Data(older.utf8))
        let storage = PhoneStorage.memory()
        let submission = AttemptSubmission(clientAttemptID: "attempt-1", questionID: "q1", response: .single(choice: 0))
        try storage.open("a1").pending.save([PendingAttempt(submission: submission, courseID: "c1", queuedAt: Date())])
        let server = StubServer(["GET /api/session": .ok(Bodies.session())])
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: server, sessionStore: InMemorySessionStore(session))
        let app = AppModel(client: client, appleSignIn: Apple(), storage: storage, connection: Connection(isOnline: false))
        #expect(app.route == .signedIn(.student()))
        #expect(app.kind == .invited)
        #expect(!app.awaitsServer)
        let offline = try #require(app.offline, "its saved courses and waiting answers are kept as ever")
        try await waitUntil { offline.waiting.map(\.id) == ["attempt-1"] }
        await app.refreshSession()
        #expect(app.route == .signedIn(.student()))
        #expect(server.calls == ["GET /api/session"])
    }

    // MARK: Words

    @Test func theEmailIsReadFromAnIdentityTokenWhenAppleNamesNone() {
        let claims = Data(#"{"sub":"x","email":"person@privaterelay.appleid.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(AppleCredential(user: "x", identityToken: "h.\(claims).s", email: nil).email == "person@privaterelay.appleid.com")
        #expect(AppleCredential(user: "x", identityToken: "h.\(claims).s", email: "named@example.com").email == "named@example.com")
        #expect(AppleCredential(user: "x", identityToken: "not a token", email: nil).email == nil)
    }

    @Test func settingsNamesTheAccountByItsEmailOrItsAppleAccount() {
        #expect(SettingsView.signedInName(.store()) == "person@privaterelay.appleid.com")
        #expect(SettingsView.signedInName(.student()) == "student@example.com")
        let hidden = Account(id: "a4", email: "001.abc.002@apple.invalid", name: "", role: .student, mustChangePassword: false, origin: .store)
        #expect(SettingsView.signedInName(hidden) == "Your Apple Account")
        let unnamed = Account(id: "a5", email: "", name: "", role: .student, mustChangePassword: false, origin: .store)
        #expect(SettingsView.signedInName(unnamed) == "Your Apple Account")
    }
}

private typealias Reply = StubServer.Reply
