import XCTest

/// Sign out everywhere in Settings, end to end against the fake server of the Debug launch seam: it
/// always asks first, signs out nowhere without an answer from QBank, and otherwise goes to sign-in
/// as a sign-out does, deleting answers still on the phone after saying so. Invented accounts only.
final class SignOutEverywhereUITests: XCTestCase {
    private static let email = "student@example.com"
    private static let password = "synthetic-pass-1"
    private static let question = "Sign out of QBank on every device, including this one?"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testSignOutEverywhereAsksThenGoesToSignIn() throws {
        let app = launch("signed-in")
        openSettings(app)
        let row = app.buttons["settings.signOutEverywhere"]
        reveal(row, in: app)
        XCTAssertEqual(row.label, "Sign out everywhere")
        attachLooks(app, "settings, sign out everywhere")

        // Tapping beside the question cancels it, and signs out nowhere.
        row.tap()
        var sheet = confirmation(app)
        XCTAssertTrue(sheet.buttons["Sign out everywhere"].exists)
        XCTAssertFalse(sheet.buttons["Sign out everywhere and delete"].exists, "no answer waits")
        // One look only: a popover keeps the look it opened in.
        attach(app, "sign out everywhere, asks")
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(sheet.disappears(timeout: 5))
        XCTAssertTrue(app.staticTexts[Self.email].exists, "still signed in")

        // Without signal no device is signed out, and Settings says why.
        setNetwork(online: false)
        row.tap()
        sheet = confirmation(app)
        sheet.buttons["Sign out everywhere"].tap()
        let problem = app.staticTexts["No connection. Check Wi-Fi or cellular data and try again."]
        XCTAssertTrue(problem.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts[Self.email].exists, "still signed in")
        XCTAssertTrue(row.isEnabled)
        attach(app, "sign out everywhere, no connection")
        setNetwork(online: true)

        row.tap()
        sheet = confirmation(app)
        sheet.buttons["Sign out everywhere"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        XCTAssertFalse(app.staticTexts["Your session ended. Sign in again."].exists, "she signed out; nothing ended her session")
        attach(app, "sign out everywhere, signed out")

        signIn(app, email: Self.email, password: Self.password)
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "her password still signs her in")
    }

    /// Answers still on the phone are named in the question, as at a sign-out, and stay when it
    /// does not go through.
    @MainActor
    func testSignOutEverywhereSaysWhatWaitingAnswersItDeletes() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        tapVisible(app.buttons["course.set.Mixed Clinical Judgment"], in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        setNetwork(online: false)
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.savedOnPhone"].appears(timeout: 5))
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.buttons["practice.close"].disappears(timeout: 5))

        openTab(app, "Settings")
        let row = app.buttons["settings.signOutEverywhere"]
        reveal(row, in: app)
        row.tap()
        let sheet = confirmation(app)
        XCTAssertTrue(sheet.staticTexts["1 answer has not reached QBank yet. Signing out deletes it from this phone."].exists)
        attach(app, "sign out everywhere, asks with an answer waiting")
        sheet.buttons["Sign out everywhere and delete"].tap()

        XCTAssertTrue(app.staticTexts["No connection. Check Wi-Fi or cellular data and try again."].appears(timeout: 5))
        let saved = app.buttons["settings.savedForOffline"]
        reveal(saved, in: app)
        XCTAssertTrue(saved.label.contains("1 waiting"), "the answer is still on the phone: \(saved.label)")
    }

    // MARK: Helpers

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].appears(timeout: 5))
    }

    /// The question Sign out everywhere asks, once it is on screen.
    @MainActor
    private func confirmation(_ app: XCUIApplication) -> XCUIElement {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.appears(timeout: 5))
        XCTAssertTrue(sheet.staticTexts[Self.question].exists)
        return sheet
    }
}
