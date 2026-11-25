import Foundation
import QBankKit
import Testing
import UIKit
@testable import QBank

/// Deleting a store account with a fresh Sign in with Apple, in the model: the order of the steps
/// (the server checked, Apple asked, this phone's copy erased, the server's account deleted, the
/// keychain cleared), and a delete that stops after the erase, which leaves only finishing it, even
/// after a relaunch, and never erases or deletes twice. Apple is a stand-in and the server a stub with
/// the contract's shapes and words. Invented data only.
@MainActor
struct AppleDeleteAccountTests {
    /// Answers in Apple's place, as Apple would after the person agreed, and writes each ask into the
    /// log with the nonce hash it was asked with.
    final class Apple: AppleSignInProvider {
        var user = TestApp.appleUser
        var isCancelled = false
        private let log: DeletionLog
        private(set) var asked: [String] = []

        init(log: DeletionLog) {
            self.log = log
        }

        func signIn(hashedNonce: String, over window: UIWindow?) async throws(AppleSignInFailure) -> AppleCredential {
            log.add("apple")
            asked.append(hashedNonce)
            if isCancelled { throw .canceled }
            return AppleCredential(user: user, identityToken: "synthetic.apple.token", email: nil, authorizationCode: "synthetic-apple-code-\(asked.count)")
        }
    }

    /// The stub server behind a log of "METHOD /path", in order with the other steps.
    final class LoggedTransport: HTTPTransport {
        let server: StubServer
        private let log: DeletionLog

        init(_ server: StubServer, log: DeletionLog) {
            self.server = server
            self.log = log
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            log.add("\(request.httpMethod ?? "?") \(request.url?.path() ?? "?")")
            return try await server.send(request)
        }
    }

    /// One phone and its server: the model, what it keeps, and the log every side writes to.
    struct Phone {
        let app: AppModel
        let server: StubServer
        let store: LoggedSessionStore
        let banks: PhoneBanks
        let storage: PhoneStorage
        let defaults: UserDefaults
        let apple: Apple
        let log: DeletionLog

        /// The same phone launched again: the same keychain, banks, storage and settings.
        @MainActor
        func relaunched() -> AppModel {
            AppleDeleteAccountTests.model(server: server, store: store, banks: banks, storage: storage, defaults: defaults, apple: apple, log: log)
        }
    }

    private static let storeUser =
        #"{"id":"a3","email":"person@privaterelay.appleid.com","name":"person","role":"student","mustChangePassword":false,"palette":"dusk","origin":"store"}"#
    private static let liveSession = StubServer.Reply.ok(#"{"user":\#(storeUser),"expiresAt":"2027-01-01T00:00:00.000Z"}"#)
    private static let deleted = StubServer.Reply.ok(#"{"status":"deleted"}"#)
    private static let ended = StubServer.Reply.error(401, "unauthenticated", "Sign in to continue.")

    private static func model(
        server: StubServer, store: LoggedSessionStore, banks: PhoneBanks, storage: PhoneStorage, defaults: UserDefaults, apple: Apple, log: DeletionLog
    ) -> AppModel {
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: LoggedTransport(server, log: log), sessionStore: store)
        return AppModel(
            client: client, banks: banks, appleSignIn: apple, look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)), highlighter: HighlighterStore(defaults: defaults),
            aiConsent: AIConsentStore(defaults: defaults), drafts: WriteDraftStore(defaults: defaults), storage: storage
        )
    }

    /// A free account signed in with Apple from an earlier launch, its bank holding one topic, and a
    /// server that answers the session and the delete.
    private func freePhone(failingErases: Int = 0, session: StoredSession? = nil) async throws -> Phone {
        let log = DeletionLog()
        let server = StubServer(["GET /api/session": Self.liveSession, "DELETE /api/me": Self.deleted])
        let store = LoggedSessionStore(session ?? StoredSession(token: TestApp.token, account: .store(), appleUser: TestApp.appleUser), log: log)
        let banks = loggedBanks(log, failingErases: failingErases)
        let storage = PhoneStorage.memory()
        let defaults = TestApp.freshDefaults()
        let apple = Apple(log: log)
        let phone = Phone(
            app: Self.model(server: server, store: store, banks: banks, storage: storage, defaults: defaults, apple: apple, log: log), server: server,
            store: store, banks: banks, storage: storage, defaults: defaults, apple: apple, log: log)
        if phone.app.bank != nil {
            _ = try await phone.app.client.createTopic(title: "Invented Pharmacology")
        }
        return phone
    }

    /// The topics in the bank of Apple's id of the person, as a new sign-in would open it.
    private func topics(in banks: PhoneBanks) async throws -> [String] {
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: try banks.open(TestApp.appleUser),
            sessionStore: InMemorySessionStore(StoredSession(token: "t")))
        return try await client.catalog().topics.map(\.title)
    }

    /// The steps logged since `start`.
    private func steps(_ log: DeletionLog, from start: Int) -> [String] {
        Array(log.steps.dropFirst(start))
    }

    private func body(of request: URLRequest?) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: try #require(request?.httpBody))
    }

    // MARK: The order

    @Test func aFreeAccountIsDeletedInOrderAndItsBankErased() async throws {
        let phone = try await freePhone()
        #expect(try await topics(in: phone.banks) == ["Invented Pharmacology"])
        let start = phone.log.steps.count
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)

        #expect(model.problem == nil)
        #expect(steps(phone.log, from: start) == ["GET /api/session", "apple", "erase bank", "DELETE /api/me", "clear keychain"])
        #expect(phone.app.route == .signedOut)
        #expect(phone.app.signedOutReason == nil)
        #expect(phone.app.bank == nil)
        #expect(try phone.store.load() == nil)

        // The server was sent Apple's fresh answer, with the very nonce Apple was asked with, and no password.
        let sent = try body(of: phone.server.requests.last)
        #expect(sent["identityToken"] == "synthetic.apple.token")
        #expect(sent["authorizationCode"] == "synthetic-apple-code-1")
        #expect(phone.apple.asked == [AppleSignInNonce(value: try #require(sent["nonce"])).hashed])
        #expect(sent["password"] == nil)

        // Signing in again as the same person finds an empty bank.
        #expect(try await topics(in: phone.banks) == [])
    }

    /// The saved courses and waiting answers a Cloud account keeps, and the sets being written, go
    /// with the bank: everything on this phone of the account.
    @Test func everythingThePhoneKeptOfTheAccountIsErasedBeforeTheServerIsAsked() async throws {
        let log = DeletionLog()
        let memory = PhoneStorage.memory()
        let storage = PhoneStorage(open: memory.open, erase: { id in log.add("erase saved \(id)") })
        let server = StubServer(["GET /api/session": Self.liveSession, "DELETE /api/me": Self.deleted])
        let store = LoggedSessionStore(StoredSession(token: TestApp.token, account: .store(), appleUser: TestApp.appleUser), log: log)
        let defaults = TestApp.freshDefaults()
        for id in [TestApp.appleUser, Account.store().id] {
            defaults.set(Data("[]".utf8), forKey: WriteDraftStore.key(for: id))
        }
        let app = Self.model(server: server, store: store, banks: loggedBanks(log), storage: storage, defaults: defaults, apple: Apple(log: log), log: log)
        let start = log.steps.count
        await AppleDeleteAccountModel(app: app).delete(over: nil)

        #expect(steps(log, from: start) == ["GET /api/session", "apple", "erase bank", "erase saved a3", "DELETE /api/me", "clear keychain"])
        #expect(defaults.data(forKey: WriteDraftStore.key(for: TestApp.appleUser)) == nil)
        #expect(defaults.data(forKey: WriteDraftStore.key(for: Account.store().id)) == nil)
    }

    // MARK: A failure after the erase

    @Test func aDeleteThatFailsAfterTheEraseIsFinishedByTryingAgainWithoutErasingTwice() async throws {
        let phone = try await freePhone()
        phone.server.script("DELETE /api/me", [.offline])
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)

        let noConnection = "No connection. Check Wi-Fi or cellular data and try again."
        #expect(model.problem == noConnection)
        #expect(phone.app.route == .finishingDeletion(.store()))
        #expect(phone.app.bank == nil, "nothing reaches the erased bank")
        #expect(try phone.store.load()?.deletion == .phoneErased)
        #expect(try phone.store.load()?.token == TestApp.token, "the session stays to finish the delete")
        #expect(phone.log.count("erase bank") == 1)

        // The screen that finishes it opens with the reason.
        let finishing = AppleDeleteAccountModel(app: phone.app)
        #expect(finishing.isFinishing)
        #expect(finishing.problem == noConnection)

        let start = phone.log.steps.count
        await finishing.delete(over: nil)
        #expect(finishing.problem == nil)
        #expect(steps(phone.log, from: start) == ["GET /api/session", "apple", "DELETE /api/me", "clear keychain"], "the erase is not done twice")
        #expect(phone.log.count("erase bank") == 1)
        #expect(phone.log.count("open bank") == 1, "the erased bank was never opened again")
        #expect(phone.app.route == .signedOut)
        #expect(try phone.store.load() == nil)

        // Each try asked Apple afresh: a token and a code are good once.
        let deletes = phone.server.requests.filter { $0.httpMethod == "DELETE" }
        #expect(deletes.count == 2)
        #expect(try body(of: deletes[0])["nonce"] != body(of: deletes[1])["nonce"])
        #expect(try body(of: deletes[1])["authorizationCode"] == "synthetic-apple-code-2")
    }

    @Test func aDeleteThatStoppedAfterTheEraseOpensOnlyToFinishAfterARelaunch() async throws {
        let phone = try await freePhone()
        phone.server.script("DELETE /api/me", [.error(503, "apple_sign_in_unavailable", "Sign in with Apple is not available yet.")])
        await AppleDeleteAccountModel(app: phone.app).delete(over: nil)
        let opened = phone.log.count("open bank")

        let relaunched = phone.relaunched()
        #expect(relaunched.route == .finishingDeletion(.store()))
        #expect(relaunched.bank == nil)
        #expect(relaunched.offline == nil)
        #expect(phone.log.count("open bank") == opened, "a relaunch does not make the erased bank again")
        let finishing = AppleDeleteAccountModel(app: relaunched)
        #expect(finishing.isFinishing)
        #expect(finishing.problem == nil, "a relaunch does not know why the last try stopped")

        // The session check of a relaunch is the finishing screen's own.
        let calls = phone.server.calls.count
        await relaunched.refreshSession()
        #expect(phone.server.calls.count == calls)

        await finishing.delete(over: nil)
        #expect(finishing.problem == nil)
        #expect(relaunched.route == .signedOut)
        #expect(phone.log.count("erase bank") == 1)
        #expect(try phone.store.load() == nil)
    }

    @Test func anEraseThatFailsIsTriedAgainAndTheServerIsNotAskedUntilItIsDone() async throws {
        let phone = try await freePhone(failingErases: 1)
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == AccountDeletionWording.phoneNotErased)
        #expect(phone.app.route == .finishingDeletion(.store()))
        #expect(try phone.store.load()?.deletion == .erasingPhone)
        #expect(!phone.server.calls.contains("DELETE /api/me"))

        let relaunched = phone.relaunched()
        #expect(relaunched.route == .finishingDeletion(.store()))
        let start = phone.log.steps.count
        await AppleDeleteAccountModel(app: relaunched).delete(over: nil)
        #expect(steps(phone.log, from: start) == ["GET /api/session", "apple", "erase bank", "DELETE /api/me", "clear keychain"])
        #expect(relaunched.route == .signedOut)
    }

    /// The server deleted the account, and its answer never reached the phone: the next try finds
    /// no session, and finishes without asking the server to delete anything again.
    @Test func anAnswerLostAfterTheServerDeletedIsFinishedWithoutDeletingAgain() async throws {
        let phone = try await freePhone()
        phone.server.script("DELETE /api/me", [.offline])
        await AppleDeleteAccountModel(app: phone.app).delete(over: nil)
        phone.server["GET /api/session"] = Self.ended
        phone.server["DELETE /api/me"] = Self.ended

        let start = phone.log.steps.count
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == nil)
        #expect(steps(phone.log, from: start) == ["GET /api/session", "clear keychain"])
        #expect(phone.app.route == .signedOut)
        #expect(phone.app.signedOutReason == AccountDeletionWording.sessionEndedAfterErasing)
        #expect(try phone.store.load() == nil)
        #expect(phone.log.count("erase bank") == 1)
    }

    /// The session ended between the check and the delete: once the erase is done, nothing more can be
    /// deleted from this phone, so it forgets the session rather than waiting forever.
    @Test func aSessionThatEndsAfterTheEraseLeavesNothingHalfDone() async throws {
        let phone = try await freePhone()
        phone.server["DELETE /api/me"] = Self.ended
        let start = phone.log.steps.count
        await AppleDeleteAccountModel(app: phone.app).delete(over: nil)
        #expect(steps(phone.log, from: start) == ["GET /api/session", "apple", "erase bank", "DELETE /api/me", "clear keychain"])
        #expect(phone.app.route == .signedOut)
        #expect(phone.app.signedOutReason == AccountDeletionWording.sessionEndedAfterErasing)
    }

    @Test func aServerRefusalAfterTheEraseIsSaidOnTheFinishingScreen() async throws {
        let phone = try await freePhone()
        let words = "Apple did not confirm it's you. Sign in with Apple again to delete your account."
        phone.server.script("DELETE /api/me", [.error(401, "invalid_apple_token", words)])
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == words)
        #expect(phone.app.route == .finishingDeletion(.store()))
        #expect(AppleDeleteAccountModel(app: phone.app).problem == words)
    }

    // MARK: Nothing erased

    @Test func anotherAppleAccountDeletesNothing() async throws {
        let phone = try await freePhone()
        phone.apple.user = "000999.someoneelse000000000000000000009.0009"
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == AccountDeletionWording.otherAppleAccount)
        #expect(phone.log.count("erase bank") == 0)
        #expect(!phone.server.calls.contains("DELETE /api/me"))
        #expect(phone.app.route == .signedIn(.store()))
        #expect(try phone.store.load()?.deletion == nil)
        #expect(try await phone.app.client.catalog().topics.map(\.title) == ["Invented Pharmacology"])
    }

    @Test func closingApplesSheetDeletesNothingAndSaysNothing() async throws {
        let phone = try await freePhone()
        phone.apple.isCancelled = true
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == nil)
        #expect(phone.log.count("erase bank") == 0)
        #expect(phone.app.route == .signedIn(.store()))
        #expect(try phone.store.load()?.deletion == nil)
    }

    @Test func aServerThatCannotBeReachedIsFoundBeforeAppleIsAsked() async throws {
        let phone = try await freePhone()
        phone.server["GET /api/session"] = .offline
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == "No connection. Check Wi-Fi or cellular data and try again.")
        #expect(phone.apple.asked.isEmpty)
        #expect(phone.log.count("erase bank") == 0)
        #expect(phone.app.route == .signedIn(.store()))
    }

    /// A free account's session can end on the server while its bank works on the phone. Found
    /// before the erase, it signs out as any ended session does, and the bank stays.
    @Test func aSessionThatEndedBeforeTheEraseSignsOutAndKeepsTheBank() async throws {
        let phone = try await freePhone()
        phone.server["GET /api/session"] = Self.ended
        await AppleDeleteAccountModel(app: phone.app).delete(over: nil)
        #expect(phone.app.route == .signedOut)
        #expect(phone.app.signedOutReason == AccountDeletionWording.sessionEndedBeforeErasing)
        #expect(phone.apple.asked.isEmpty)
        #expect(phone.log.count("erase bank") == 0)
        #expect(try await topics(in: phone.banks) == ["Invented Pharmacology"])
    }

    @Test func whileTheServerHasNotConfirmedTheSignInNothingIsDeleted() async throws {
        let unsent = AppleSignInRequest(identityToken: "synthetic.apple.token", nonce: String(repeating: "c", count: 64))
        let phone = try await freePhone(session: StoredSession(token: "", account: .store(), appleUser: TestApp.appleUser, unsent: unsent))
        phone.server["POST /api/sign-in/apple"] = .offline
        #expect(phone.app.awaitsServer)
        let model = AppleDeleteAccountModel(app: phone.app)
        await model.delete(over: nil)
        #expect(model.problem == AccountDeletionWording.awaitsServer)
        #expect(phone.apple.asked.isEmpty)
        #expect(phone.log.count("erase bank") == 0)
        #expect(!phone.server.calls.contains("DELETE /api/me"))
    }

    // MARK: Who deletes how

    @Test func aStoreAccountDeletesWithAppleAndAnInvitedOneWithItsPassword() {
        #expect(AppleDeleteAccountModel.isOffered(to: .store(), kind: .free))
        #expect(AppleDeleteAccountModel.isOffered(to: .store(), kind: .store))
        #expect(!AppleDeleteAccountModel.isOffered(to: .student(), kind: .invited))
        #expect(!AppleDeleteAccountModel.isOffered(to: .admin, kind: .invited))
        #expect(!AppleDeleteAccountModel.isOffered(to: nil, kind: .free))
        #expect(!DeleteAccountModel.isOffered(to: .store(), kind: .free))
        #expect(DeleteAccountModel.isOffered(to: .student(), kind: .invited))
    }

    @Test func anInvitedAccountCannotBeDeletedWithApple() async throws {
        let server = StubServer()
        let (app, store) = TestApp.make(server, account: .student())
        let credential = AppleCredential(user: TestApp.appleUser, identityToken: "synthetic.apple.token", email: nil, authorizationCode: "code")
        await #expect(throws: AppModel.DeletionStop.self) {
            try await app.deleteAccount(confirmedWith: credential, nonce: AppleSignInNonce())
        }
        #expect(app.route == .signedIn(.student()))
        #expect(server.requests.isEmpty)
        #expect(try store.load()?.deletion == nil)
    }
}
