import XCTest

/// The update from the release before Sign in with Apple, end to end: an account the owner set up
/// keeps the session that release stored, so its phone opens signed in on its last course and never
/// shows the first screen, and an answer it left waiting reaches QBank. A unit test cannot do this
/// job: only a relaunch of the real app over the session in the bytes the earlier release wrote, and
/// over the answers it kept on the phone, shows the update signs nobody out and loses no answer.
/// Invented accounts only.
final class UpgradeUITests: XCTestCase {
    private static let set = "Anxiety, Panic, and Anxiolytics"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testAStoredSessionStaysSignedInAfterTheUpdate() throws {
        // Before the update: signed in, with an answer given without signal waiting on the phone.
        let before = launch("signed-in")
        XCTAssertTrue(before.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(before, "Week 3", on: "Exam 2")
        let set = before.buttons["course.set.\(Self.set)"]
        tapVisible(set, in: before)
        XCTAssertTrue(before.buttons["practice.close"].appears(timeout: 5))
        setNetwork(online: false)
        tapVisible(before.buttons["practice.option.0"], in: before)
        before.buttons["practice.check"].tap()
        let waiting = before.buttons["practice.waiting"]
        XCTAssertTrue(waiting.appears(timeout: 5))
        XCTAssertEqual(waiting.label, "1 waiting to send")
        before.terminate()

        // After it: the session as the earlier release stored it, and the phone's files as it left them.
        let app = launch("stored-session-before-update", keepPhoneData: true)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "still signed in, on her last course")
        XCTAssertFalse(app.staticTexts["signIn.title"].exists, "the first screen never shows")
        XCTAssertFalse(app.buttons["welcome.apple"].exists)
        attach(app, "after the update, signed in")

        // The fake server starts afresh, so the one answer it has is the one that waited.
        openFolder(app, "Week 3", on: "Exam 2")
        let sent = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(sent.appears(timeout: 10))
        waitForLabel(sent, containing: "1 of 13 answered")
        XCTAssertFalse(app.buttons["home.waiting"].exists)

        openTab(app, "Settings")
        XCTAssertTrue(app.staticTexts["student@example.com"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["settings.changePassword"].exists, "the same invited account, with its password")
        attach(app, "after the update, settings")
    }
}
