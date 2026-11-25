import XCTest

/// The first screen end to end: Sign in with Apple, with the scripted sheet of the Debug launch seam
/// (`QB_UITEST_APPLE`) in Apple's place, and the small door to the email and password of an account
/// the owner set up. A unit test cannot do this job: it is Apple's own button on the real screen, the
/// door that opens below it, and the screens each sign-in lands on that show where the person ends up.
/// Invented accounts only; no real Apple Account and no real server.
final class WelcomeUITests: XCTestCase {
    private let topic = "Getting started"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        // IPadUITests walks the iPad's layout of this screen.
        try skipOnIPad()
    }

    /// A new person signs in with Apple and lands in a bank on this iPhone, with the sample set and
    /// none of the server's courses, which works with no network. Signing out keeps it, and signing in
    /// again opens it where they left it.
    @MainActor
    func testSignInWithAppleOpensTheBankOnThisIPhone() throws {
        let app = launch("signed-out", environment: ["QB_UITEST_APPLE": "new-person"])
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        let apple = app.buttons["welcome.apple"]
        XCTAssertTrue(apple.appears(timeout: 5))
        XCTAssertTrue(apple.isHittable)
        XCTAssertTrue(app.buttons["welcome.useExistingAccount"].exists)
        XCTAssertFalse(app.textFields["signIn.email"].exists, "the email door stays closed until she asks for it")
        XCTAssertFalse(app.buttons["Sign up"].exists, "signing up is on the web only")
        XCTAssertTrue(app.buttons["welcome.privacy"].exists, "the privacy policy is readable before signing in")
        XCTAssertTrue(app.buttons["welcome.terms"].exists)
        expectNoPasskeys(app)
        attachLooks(app, "welcome")

        apple.tap()
        let card = app.buttons["home.topic.\(topic)"]
        XCTAssertTrue(card.appears(timeout: 10), "a new bank on this iPhone, with the sample set")
        XCTAssertFalse(app.buttons["home.course.NURS 310"].exists, "none of the server's courses")
        XCTAssertTrue(app.staticTexts["signIn.title"].disappears(timeout: 5), "the first screen has gone")
        attach(app, "signed in with Apple, home")

        // The bank is on the phone: it opens with no network at all.
        setNetwork(online: false)
        card.tap()
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        XCTAssertTrue(app.buttons["folder.Unsorted"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["course.offline"].exists)
        app.navigationBars[topic].buttons["Home"].tap()
        setNetwork(online: true)

        openTab(app, "Settings")
        XCTAssertTrue(app.staticTexts["new.person@privaterelay.appleid.com"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["settings.changePassword"].exists)
        XCTAssertFalse(app.buttons["settings.connectAgent"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings.awaitsServer"].exists, "the server confirmed the sign-in")
        attach(app, "signed in with Apple, settings")

        tapVisible(app.buttons["settings.signOut"], in: app)
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        app.buttons["welcome.apple"].tap()
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10), "signing in again opens the same bank, on the topic used last")
        XCTAssertTrue(app.buttons["folder.Unsorted"].appears(timeout: 5))
    }

    /// The door below Sign in with Apple: an account the owner set up signs in with its email and
    /// password and lands on its last course on the server. An Apple email that belongs to such an
    /// account is refused and sent to this door, with the email filled in.
    @MainActor
    func testAnExistingAccountSignsInWithEmail() throws {
        let app = launch("signed-out", environment: ["QB_UITEST_APPLE": "password-email"])
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        app.buttons["welcome.useExistingAccount"].tap()
        let email = app.textFields["signIn.email"]
        XCTAssertTrue(email.appears(timeout: 5))
        XCTAssertTrue(app.secureTextFields["signIn.password"].exists)
        XCTAssertTrue(app.buttons["signIn.forgot"].exists)
        XCTAssertFalse(app.buttons["welcome.useExistingAccount"].exists)
        XCTAssertTrue(app.buttons["welcome.apple"].exists, "Sign in with Apple stays on offer")
        attach(app, "welcome, email door")

        app.buttons["welcome.apple"].tap()
        let refused = app.staticTexts["This email already has a QBank account with a password. Sign in with your email and password instead."]
        XCTAssertTrue(refused.appears(timeout: 5))
        XCTAssertEqual(email.value as? String, "student@example.com", "the door has the account's email")
        attach(app, "welcome, apple email has a password account")

        signIn(app, email: nil, password: "synthetic-pass-1")
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "its last course, on the server")
        XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))
        openTab(app, "Settings")
        XCTAssertTrue(app.staticTexts["student@example.com"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["settings.changePassword"].exists)
        XCTAssertTrue(app.buttons["settings.savedForOffline"].exists)
    }
}
