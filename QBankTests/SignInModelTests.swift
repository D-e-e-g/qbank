import QBankKit
import Testing
@testable import QBank

@MainActor
struct SignInModelTests {
    @Test func signInStoresTheSessionAndOpensTheApp() async throws {
        let server = StubServer(["POST /api/sign-in/password": .ok(Bodies.signedIn())])
        let (app, store) = TestApp.make(server)
        let model = SignInModel(app: app)
        model.email = "  student@example.com "
        model.password = "synthetic-pass-1"
        await model.signIn()
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load()?.token == "synthetic-new-token")
        #expect(model.problem == nil)
        let body = try #require(server.requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains(#""email":"student@example.com""#))
    }

    @Test func wrongPasswordSaysSoAndClearsThePassword() async {
        let server = StubServer(["POST /api/sign-in/password": .error(401, "invalid_credentials", "That email or password is not right.")])
        let (app, _) = TestApp.make(server)
        let model = SignInModel(app: app)
        model.email = "student@example.com"
        model.password = "not-it"
        await model.signIn()
        #expect(app.route == .signedOut)
        #expect(model.problem == "That email or password is not right.")
        #expect(model.password.isEmpty)
        #expect(model.email == "student@example.com")
        #expect(model.isSigningIn == false)
    }

    @Test func lockedSignInSaysHowLong() async {
        let server = StubServer(["POST /api/sign-in/password": .error(429, "too_many_attempts", "Too many tries. Try again in 15 minutes.")])
        let (app, _) = TestApp.make(server)
        let model = SignInModel(app: app)
        model.email = "student@example.com"
        model.password = "wrong"
        await model.signIn()
        #expect(model.problem == "Too many tries. Try again in 15 minutes.")
    }

    @Test func noSignalIsSaidPlainly() async {
        let (app, _) = TestApp.make(StubServer(["POST /api/sign-in/password": .offline]))
        let model = SignInModel(app: app)
        model.email = "student@example.com"
        model.password = "synthetic-pass-1"
        await model.signIn()
        #expect(model.problem == "No connection. Check Wi-Fi or cellular data and try again.")
    }

    @Test func temporaryPasswordLeadsToChoosingANewOne() async {
        let server = StubServer(["POST /api/sign-in/password": .ok(Bodies.signedIn(mustChangePassword: true))])
        let (app, _) = TestApp.make(server)
        let model = SignInModel(app: app)
        model.email = "student@example.com"
        model.password = "synthetic-temp-1"
        await model.signIn()
        #expect(app.route == .choosingPassword(.student(mustChangePassword: true)))
        #expect(app.temporaryPassword == "synthetic-temp-1")
    }

    @Test func needsBothFieldsBeforeSending() async {
        let server = StubServer()
        let (app, _) = TestApp.make(server)
        let model = SignInModel(app: app)
        model.email = "   "
        model.password = "x"
        await model.signIn()
        #expect(model.problem == "Enter your email and password.")
        #expect(server.requests.isEmpty)
    }

    /// The first screen says it above both doors, and the email door starts with nothing to say.
    @Test func showsWhyTheLastSessionEnded() async {
        let server = StubServer(["GET /api/session": .error(401, "unauthenticated", "Sign in to continue.")])
        let (app, _) = TestApp.make(server, account: .student())
        await app.refreshSession()
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == "Your session ended. Sign in again.")
        #expect(SignInModel(app: app).problem == nil)
    }
}

@MainActor
struct ChoosePasswordModelTests {
    private func appAfterTemporarySignIn(_ server: StubServer) async -> AppModel {
        server["POST /api/sign-in/password"] = .ok(Bodies.signedIn(mustChangePassword: true))
        let (app, _) = TestApp.make(server)
        let signIn = SignInModel(app: app)
        signIn.email = "student@example.com"
        signIn.password = "synthetic-temp-1"
        await signIn.signIn()
        return app
    }

    @Test func offersTheTemporaryPasswordSheJustTyped() async {
        let app = await appAfterTemporarySignIn(StubServer())
        #expect(ChoosePasswordModel(app: app).temporaryPassword == "synthetic-temp-1")
    }

    @Test func savingANewPasswordOpensTheApp() async throws {
        let server = StubServer(["POST /api/account/password": .ok(Bodies.signedIn(token: "synthetic-fresh-token"))])
        let app = await appAfterTemporarySignIn(server)
        let model = ChoosePasswordModel(app: app)
        model.newPassword = "a-new-password"
        await model.save()
        #expect(app.route == .signedIn(.student()))
        #expect(app.temporaryPassword == nil)
        #expect(try app.client.storedSession()?.token == "synthetic-fresh-token")
        let body = try #require(server.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"currentPassword":"synthetic-temp-1","newPassword":"a-new-password"}"#)
    }

    @Test func emptyFieldsAreCaughtBeforeSending() async {
        let server = StubServer()
        let app = await appAfterTemporarySignIn(server)
        let model = ChoosePasswordModel(app: app)
        await model.save()
        #expect(model.problem == "Enter the temporary password and a new one.")
        #expect(server.calls == ["POST /api/sign-in/password"])
    }

    @Test func tooShortIsCaughtBeforeSending() async {
        let server = StubServer()
        let app = await appAfterTemporarySignIn(server)
        let model = ChoosePasswordModel(app: app)
        model.newPassword = "short"
        await model.save()
        #expect(model.problem == "Choose a password of at least 8 characters.")
        #expect(server.calls == ["POST /api/sign-in/password"])
    }

    @Test func wrongTemporaryPasswordSaysSo() async {
        let server = StubServer(["POST /api/account/password": .error(401, "invalid_credentials", "That password is not right.")])
        let app = await appAfterTemporarySignIn(server)
        let model = ChoosePasswordModel(app: app)
        model.temporaryPassword = "not-it"
        model.newPassword = "a-new-password"
        await model.save()
        #expect(model.problem == "That password is not right.")
        #expect(app.route == .choosingPassword(.student(mustChangePassword: true)))
    }

    @Test func backToSignInEndsTheSession() async throws {
        let server = StubServer(["POST /api/sign-out": .ok(#"{"status":"ok"}"#)])
        let app = await appAfterTemporarySignIn(server)
        await ChoosePasswordModel(app: app).cancel()
        #expect(app.route == .signedOut)
        #expect(try app.client.storedSession() == nil)
    }
}
