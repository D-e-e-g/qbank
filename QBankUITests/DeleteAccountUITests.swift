import XCTest

/// Delete account in each kind of account the app runs. A store account, free on this iPhone, has no
/// password: a fresh Sign in with Apple confirms the delete, which erases this iPhone's bank, then
/// deletes the account on the server, and a delete that stops after the erase offers finishing it or
/// signing out. An invited account still deletes with its password. The app has no Cloud mode yet, and a Cloud
/// account takes the same screen and steps as a free one. A unit test cannot do this job: it is the
/// real Settings row, the screen it opens for the account's kind, Apple's step through the Debug seam,
/// and the screen that follows, over the bank on the phone, that show the person can find, confirm and
/// finish the delete, and that nothing of the bank is left. Invented accounts and topics only.
final class DeleteAccountUITests: XCTestCase {
    private let topic = "Invented Delete Notes"
    /// Apple answers as the store account the free scenarios are signed in as.
    private let samePerson = ["QB_UITEST_APPLE": "returning-person"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAFreeAccountIsDeletedAfterAFreshSignInWithApple() throws {
        try skipOnIPad()
        let app = launch("free-new-bank", environment: samePerson)
        makeTopic(app)

        openDeleteAccount(app)
        let message = app.staticTexts["deleteAccount.message"]
        // A free bank is on this iPhone alone: the server holds only the account.
        XCTAssertTrue(message.label.contains("deleted for good from QBank's server, and everything in it is erased from this iPhone"), message.label)
        XCTAssertFalse(message.label.contains("signed out on every device"), "another device keeps its own bank")
        XCTAssertTrue(message.label.contains("there is no Undo"), message.label)
        let subscription = app.staticTexts["deleteAccount.subscription"]
        XCTAssertTrue(subscription.label.contains("does not cancel a QBank Cloud subscription"), subscription.label)
        XCTAssertTrue(app.buttons["deleteAccount.manageSubscription"].exists)
        XCTAssertTrue(app.staticTexts["deleteAccount.apple"].exists)
        XCTAssertFalse(app.secureTextFields["deleteAccount.password"].exists, "a store account has no password")
        attachLooks(app, "delete account, free")

        app.buttons["deleteAccount.delete"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        attach(app, "delete account, free, deleted")

        // The same Apple Account signs in to a new account, whose bank is empty: the topic went with the old one.
        app.buttons["welcome.apple"].tap()
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        XCTAssertFalse(app.buttons["home.topic.\(topic)"].exists, "the bank was erased")
    }

    /// The server can take a while to delete a store account, after this iPhone's copy is erased.
    /// The delete is under way all that time, so nothing on screen says it stopped.
    @MainActor
    func testAFreeAccountsDeleteNeverShowsTheFinishingScreenOnItsWayToSignIn() throws {
        try skipOnIPad()
        let app = launch("free-delete-held", environment: samePerson)
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openDeleteAccount(app)
        app.buttons["deleteAccount.delete"].tap()

        watchTheDeleteUnderWay(app)
        waitForLabel(app.staticTexts["deleteAccount.message"], containing: "deleted for good from QBank's server")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no screen of the erased bank stays")
        attachLooks(app, "delete account, free, under way")

        releaseTheDeleteAndExpectSignIn(app)
    }

    @MainActor
    func testAnInvitedAccountsDeleteNeverShowsTheFinishingScreenOnItsWayToSignIn() throws {
        try skipOnIPad()
        let app = launch("signed-in-delete-held")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openDeleteAccount(app)
        let password = app.secureTextFields["deleteAccount.password"]
        password.tap()
        password.typeText("synthetic-pass-1")
        app.buttons["deleteAccount.delete"].tap()

        watchTheDeleteUnderWay(app)
        attach(app, "delete account, invited, under way")

        releaseTheDeleteAndExpectSignIn(app)
    }

    @MainActor
    func testADeleteThatStopsAfterTheEraseIsFinishedByTryingAgain() throws {
        try skipOnIPad()
        // The first request to delete the account loses its connection, after this iPhone's copy is erased.
        let app = launch("free-delete-drops", environment: samePerson)
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openDeleteAccount(app)
        app.buttons["deleteAccount.delete"].tap()

        waitForLabel(app.staticTexts["deleteAccount.message"], containing: "is not deleted yet")
        XCTAssertTrue(app.staticTexts["No connection. Check Wi-Fi or cellular data and try again."].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "only finishing the delete or signing out is offered")
        XCTAssertTrue(app.staticTexts["deleteAccount.subscription"].exists)
        attachLooks(app, "delete account, finishing")

        app.buttons["deleteAccount.delete"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
    }

    @MainActor
    func testADeleteThatStopsAfterTheEraseCanBeLeftBySigningOut() throws {
        try skipOnIPad()
        let app = launch("free-delete-drops", environment: samePerson)
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openDeleteAccount(app)
        app.buttons["deleteAccount.delete"].tap()

        waitForLabel(app.staticTexts["deleteAccount.message"], containing: "is not deleted yet")
        XCTAssertTrue(app.staticTexts["deleteAccount.signOutNote"].exists)
        attach(app, "delete account, finishing, sign out")
        app.buttons["deleteAccount.signOut"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
    }

    @MainActor
    func testAnInvitedAccountStillDeletesWithItsPassword() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openDeleteAccount(app)
        let password = app.secureTextFields["deleteAccount.password"]
        XCTAssertTrue(password.exists)
        XCTAssertFalse(app.staticTexts["deleteAccount.subscription"].exists, "an invited account buys nothing from Apple")
        XCTAssertFalse(app.buttons["deleteAccount.manageSubscription"].exists)
        XCTAssertFalse(app.staticTexts["deleteAccount.apple"].exists)
        attach(app, "delete account, invited")

        password.tap()
        password.typeText("synthetic-pass-1")
        app.buttons["deleteAccount.delete"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
    }

    // MARK: Helpers

    /// With the server's answer held back: the delete shows under way, and not as one to finish.
    @MainActor
    private func watchTheDeleteUnderWay(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Deleting"].appears(timeout: 10), "the delete is under way")
        expectNoFinishingScreen(app)
    }

    /// Lets the server's answer through, and looks again and again until sign-in is up, so the
    /// screens in between are seen too.
    @MainActor
    private func releaseTheDeleteAndExpectSignIn(_ app: XCUIApplication) {
        postDebugNotification("com.dimitrygallego.qbank.uitest.accountDelete.release")
        let signIn = app.staticTexts["signIn.title"]
        let deadline = Date(timeIntervalSinceNow: 20)
        repeat {
            expectNoFinishingScreen(app)
        } while !signIn.exists && Date() < deadline
        XCTAssertTrue(signIn.exists)
        expectNoFinishingScreen(app)
    }

    /// Nothing on screen says the account is not deleted yet, or offers to sign out of the delete.
    @MainActor
    private func expectNoFinishingScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let unfinished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not deleted yet"))
        XCTAssertEqual(unfinished.count, 0, "the finishing screen's text is on screen", file: file, line: line)
        XCTAssertFalse(app.buttons["deleteAccount.signOut"].exists, "the finishing screen's Sign out is on screen", file: file, line: line)
    }

    /// Makes a study topic from Home's +, in the bank on the phone.
    @MainActor
    private func makeTopic(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText(topic)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))
    }

    /// Settings > Delete account.
    @MainActor
    private func openDeleteAccount(_ app: XCUIApplication) {
        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].appears(timeout: 5))
        let row = app.buttons["settings.deleteAccount"]
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["Delete account"].appears(timeout: 5))
    }
}
