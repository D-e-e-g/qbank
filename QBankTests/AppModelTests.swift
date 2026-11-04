import Foundation
import QBankKit
import Testing
@testable import QBank

@MainActor
struct AppModelTests {
    @Test func noStoredSessionStartsSignedOut() {
        let (app, _) = TestApp.make(StubServer())
        #expect(app.route == .signedOut)
        #expect(app.account == nil)
    }

    @Test func storedSessionStartsSignedInWithoutAskingTheServer() {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student())
        #expect(app.route == .signedIn(.student()))
        #expect(server.requests.isEmpty)
    }

    @Test func storedTemporaryPasswordStartsOnChoosePassword() {
        let (app, _) = TestApp.make(StubServer(), account: .student(mustChangePassword: true))
        #expect(app.route == .choosingPassword(.student(mustChangePassword: true)))
    }

    @Test func endedSessionSignsOutAndSaysWhy() async throws {
        let server = StubServer(["GET /api/session": .error(401, "unauthenticated", "Sign in to continue.")])
        let (app, store) = TestApp.make(server, account: .student())
        await app.refreshSession()
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == "Your session ended. Sign in again.")
        #expect(try store.load() == nil)
    }

    @Test func noSignalKeepsHerSignedIn() async throws {
        let server = StubServer(["GET /api/session": .offline])
        let (app, store) = TestApp.make(server, account: .student())
        await app.refreshSession()
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load() != nil)
    }

    @Test func sessionCheckPicksUpAPasswordReset() async {
        let server = StubServer(["GET /api/session": .ok(Bodies.session(mustChangePassword: true))])
        let (app, _) = TestApp.make(server, account: .student())
        await app.refreshSession()
        #expect(app.route == .choosingPassword(.student(mustChangePassword: true)))
    }

    @Test func signOutForgetsTheSessionEvenWithoutSignal() async throws {
        let server = StubServer(["POST /api/sign-out": .offline])
        let (app, store) = TestApp.make(server, account: .student())
        app.hasLanded = true
        await app.signOut()
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == nil)
        #expect(app.hasLanded == false)
        #expect(try store.load() == nil)
        #expect(server.calls == ["POST /api/sign-out"])
    }

    /// Each sign-in counts, so the same account signing in again starts from fresh screens.
    @Test func eachSignInCounts() async {
        let server = StubServer(["POST /api/sign-out": .ok(#"{"status":"ok"}"#), "POST /api/sign-in/password": .ok(Bodies.signedIn())])
        let (app, _) = TestApp.make(server, account: .student())
        #expect(app.signIns == 0)
        await app.signOut()
        let signIn = SignInModel(app: app)
        signIn.email = "student@example.com"
        signIn.password = "synthetic-pass-1"
        await signIn.signIn()
        #expect(app.signIns == 1)
        #expect(app.route == .signedIn(.student()))
    }

    @Test func mustChangePasswordFromAnyCallOpensChoosePassword() {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        let handled = app.handle(.server(ServerError(status: 403, code: .mustChangePassword, message: "Choose a new password to continue.")))
        #expect(handled)
        #expect(app.route == .choosingPassword(.student()))
    }

    @Test func otherFailuresAreLeftToTheScreen() {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        #expect(app.handle(.transport(.notConnectedToInternet)) == false)
        #expect(app.handle(.server(ServerError(status: 404, code: .requestRefused, message: "Gone"))) == false)
        #expect(app.route == .signedIn(.student()))
    }

    static func waitingAnswer(_ app: AppModel) async throws {
        let submission = AttemptSubmission(clientAttemptID: "w1", questionID: "q1", response: .single(choice: 0))
        _ = try await app.submit(submission, courseID: "c1")
    }

    @Test func signedInSheGetsTheStoreForHerAccount() {
        let (app, _) = TestApp.make(StubServer(), account: .student())
        #expect(app.offline?.accountID == "a1")
        let (signedOut, _) = TestApp.make(StubServer())
        #expect(signedOut.offline == nil)
    }

    @Test func signOutDeletesWhatThePhoneKeptForHer() async throws {
        let storage = PhoneStorage.memory()
        let server = StubServer(["GET /api/semesters": .ok(Bodies.semesters()), "POST /api/sign-out": .ok(#"{"status":"ok"}"#)])
        let (app, _) = TestApp.make(server, account: .student(), storage: storage, connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        _ = try await app.offline?.load(.catalog) { () async throws(QBankError) in try await app.client.catalog() }
        await app.signOut()
        #expect(app.offline == nil)

        let (again, _) = TestApp.make(server, account: .student(), storage: storage)
        #expect(again.offline?.waiting.isEmpty == true)
        #expect(await again.offline?.saved(.catalog) == nil)
    }

    @Test func signOutLeavesNoFilesOfHersOnThePhone() async throws {
        let folder = OfflineStoreTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = StubServer(["GET /api/semesters": .ok(Bodies.semesters()), "POST /api/sign-out": .ok(#"{"status":"ok"}"#)])
        let connection = Connection()
        let (app, _) = TestApp.make(server, account: .student(), storage: .files(root: folder), connection: connection)
        await HomeModel(app: app).load()
        connection.update(isOnline: false)
        try await Self.waitingAnswer(app)
        let account = folder.appendingPathComponent("Accounts/a1")
        #expect(FileManager.default.fileExists(atPath: account.appendingPathComponent("pending-attempts.json").path()))
        #expect(FileManager.default.fileExists(atPath: account.appendingPathComponent("Content").path()))

        await app.signOut()
        #expect(!FileManager.default.fileExists(atPath: account.path()))
    }

    /// Once every session has ended, the phone forgets her as a sign-out does, waiting answers too.
    @Test func signOutEverywhereForgetsHerAndWhatThePhoneKept() async throws {
        let storage = PhoneStorage.memory()
        let server = StubServer(["POST /api/sign-out/everywhere": .ok(#"{"status":"signed_out_everywhere"}"#)])
        let (app, store) = TestApp.make(server, account: .student(), storage: storage, connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        app.hasLanded = true
        try await app.signOutEverywhere()
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == nil)
        #expect(app.hasLanded == false)
        #expect(app.offline == nil)
        #expect(try store.load() == nil)
        #expect(server.calls == ["POST /api/sign-out/everywhere"])

        let (again, _) = TestApp.make(server, account: .student(), storage: storage)
        #expect(again.offline?.waiting.isEmpty == true)
    }

    /// Unlike a sign-out, no answer from QBank keeps her signed in with everything the phone kept:
    /// her other devices may still be signed in.
    @Test(arguments: [
        StubServer.Reply.offline,
        StubServer.Reply.error(502, "auth_failed", "Signing out everywhere did not work. Try again."),
    ])
    func signOutEverywhereThatDidNotEndThemKeepsHerSignedIn(reply: StubServer.Reply) async throws {
        let server = StubServer(["POST /api/sign-out/everywhere": reply])
        let (app, store) = TestApp.make(server, account: .student(), storage: .memory(), connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        let error = await #expect(throws: QBankError.self) { try await app.signOutEverywhere() }
        #expect(error?.needsSignIn == false)
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load() != nil)
        #expect(app.offline?.waiting.map(\.id) == ["w1"])
    }

    /// A session that had already ended goes to sign-in as any ended session does, keeping the
    /// answers for her next sign-in.
    @Test func signOutEverywhereFromAnEndedSessionGoesToSignIn() async throws {
        let storage = PhoneStorage.memory()
        let server = StubServer(["POST /api/sign-out/everywhere": .error(401, "unauthenticated", "Sign in to continue.")])
        let (app, store) = TestApp.make(server, account: .student(), storage: storage, connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        try await app.signOutEverywhere()
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == "Your session ended. Sign in again.")
        #expect(try store.load() == nil)

        let (again, _) = TestApp.make(StubServer(), account: .student(), storage: storage)
        #expect(again.offline?.waiting.map(\.id) == ["w1"])
    }

    @Test func anEndedSessionKeepsTheAnswersForHerNextSignIn() async throws {
        let storage = PhoneStorage.memory()
        let (app, _) = TestApp.make(StubServer(), account: .student(), storage: storage, connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        app.handle(.server(ServerError(status: 401, code: .unauthenticated, message: "Sign in to continue.")))
        #expect(app.offline == nil)

        let (again, _) = TestApp.make(StubServer(), account: .student(), storage: storage)
        #expect(again.offline?.waiting.map(\.id) == ["w1"])
    }

    @Test func eachAccountKeepsItsOwnAnswers() async throws {
        let storage = PhoneStorage.memory()
        let (app, _) = TestApp.make(StubServer(), account: .student(), storage: storage, connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        let other = Account(id: "a3", email: "other@example.com", name: "Other Student", role: .student, mustChangePassword: false)
        let (otherApp, _) = TestApp.make(StubServer(), account: other, storage: storage)
        #expect(otherApp.offline?.waiting.isEmpty == true)
    }

    @Test func theConnectionComingBackSendsTheWaitingAnswers() async throws {
        let server = StubServer()
        let connection = Connection(isOnline: false)
        let (app, _) = TestApp.make(server, account: .student(), connection: connection)
        try await Self.waitingAnswer(app)
        server["POST /api/attempts"] = StubServer.Reply(status: 201, body: PracticeModelTests.saved(id: "w1", question: "q1", status: "correct", points: 1, max: 1))
        connection.update(isOnline: true)
        try await waitUntil { app.offline?.waiting.isEmpty == true }
        #expect(server.sentAttemptIDs == ["w1"])
    }

    @Test func answersLeftWaitingGoAtLaunch() async throws {
        let storage = PhoneStorage.memory()
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student(), storage: storage, connection: Connection(isOnline: false))
        try await Self.waitingAnswer(app)
        server["POST /api/attempts"] = StubServer.Reply(status: 201, body: PracticeModelTests.saved(id: "w1", question: "q1", status: "correct", points: 1, max: 1))
        let (relaunched, _) = TestApp.make(server, account: .student(), storage: storage)
        try await waitUntil { relaunched.offline?.waiting.isEmpty == true }
        #expect(server.sentAttemptIDs == ["w1"])
    }
}
