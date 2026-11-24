import XCTest

/// A free account on this iPhone: its bank is on the phone, so with no network at all it can make a
/// topic, import a question file, practice and review, and Settings offers only what such an account
/// can do. Invented topics and question files only. A unit test cannot do this job: it is the real
/// screens running over the bank on the phone, with the network off, that shows nothing waits for a
/// connection and nothing a free account cannot use is on screen.
final class FreeModeUITests: XCTestCase {
    private let topic = "Invented Sleep Notes"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testANewBankPracticesAndReviewsWithNoNetwork() throws {
        try skipOnIPad()
        let app = launch("free-new-bank", online: false)

        // A new bank is empty: Home leads with topics, and the + makes one with no network.
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        attach(app, "free new bank, home")
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText(topic)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["This topic has no question sets yet."].exists)

        // Import checks and files a question file on the phone.
        openTab(app, "Add")
        XCTAssertTrue(app.navigationBars["Add questions"].appears(timeout: 5))
        app.buttons["add.import"].tap()
        XCTAssertTrue(app.navigationBars["Import"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["import.offline"].exists, "import does not wait for a connection")
        waitForLabel(app.buttons["import.course"], containing: topic)
        paste(AddUITests.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        let ready = app.descendants(matching: .any)["import.ready"]
        XCTAssertTrue(ready.appears(timeout: 5))
        XCTAssertEqual(ready.label, "Ready: 3 questions, 1 term")
        tapVisible(app.buttons["import.commit"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["import.done.title"].label, "Imported")
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))

        // Practice: an answer flagged as a guess goes to Review whether or not it is right.
        let set = app.buttons["course.set.Invented Sleep and Rest"]
        XCTAssertTrue(set.appears(timeout: 5))
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 3"))
        tapVisible(app.switches["practice.guess"], in: app)
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        let feedback = app.descendants(matching: .any)["practice.feedback"]
        XCTAssertTrue(feedback.appears(timeout: 5))
        XCTAssertTrue(feedback.label.contains("Flagged as a guess"), feedback.label)
        attach(app, "free new bank, practice")
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        waitForLabel(set, containing: "1 of 3 answered")

        // Review lists it, and practicing the list works with no network too.
        goBack(app, from: "Unsorted")
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        let tile = app.buttons["course.tile.review"]
        XCTAssertTrue(tile.appears(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["Guessed 1"].appears(timeout: 5))
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'review.question.'"))
        XCTAssertEqual(listed.count, 1)
        attach(app, "free new bank, review")
        tapVisible(app.buttons["Practice these 1 (shuffled)"], in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 1"))
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))

        // Settings offers what this account can do: no password, agent or saved courses.
        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].appears(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["settings.account"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["settings.signOut"].exists)
        XCTAssertFalse(app.buttons["settings.changePassword"].exists)
        XCTAssertFalse(app.buttons["settings.connectAgent"].exists)
        XCTAssertFalse(app.buttons["settings.savedForOffline"].exists)
        attach(app, "free new bank, settings")
    }

    /// After a free account signs out, an invited account that signs in with its password gets the
    /// server's bank, not the free bank left on the phone, and Settings offers what it can do. A unit
    /// test cannot do this job: it is the real sign-out and sign-in screens over the free model's
    /// transport that show the account's bank and Settings rows follow the account that signed in.
    @MainActor
    func testAPasswordSignInAfterAFreeSignOutUsesTheServer() throws {
        try skipOnIPad()
        let app = launch("free-new-bank")
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))

        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].appears(timeout: 5))
        tapVisible(app.buttons["settings.signOut"], in: app)
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))

        signIn(app, email: "student@example.com", password: "synthetic-pass-1")
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "the server's bank, not the free one")
        XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))
        attach(app, "invited after free sign-out, course")

        openTab(app, "Settings")
        XCTAssertTrue(app.staticTexts["student@example.com"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["settings.changePassword"].exists)
        XCTAssertTrue(app.buttons["settings.connectAgent"].exists)
        XCTAssertTrue(app.buttons["settings.savedForOffline"].exists)
        attach(app, "invited after free sign-out, settings")
    }

    /// Export my bank opens the system share sheet with the bank's file, with no network at all. A
    /// unit test cannot do this job: the sheet is the system's, over the real Settings screen, and
    /// only a launch shows that the row is there and the sheet opens with a named file.
    @MainActor
    func testExportMyBankOpensTheShareSheetWithNoNetwork() throws {
        try skipOnIPad()
        let app = launch("free-new-bank", online: false)
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openTab(app, "Settings")
        XCTAssertTrue(app.navigationBars["Settings"].appears(timeout: 5))
        let row = app.buttons["settings.exportBank"]
        reveal(row, in: app)
        attach(app, "free settings, export my bank")
        row.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.appears(timeout: 15), "the share sheet opens")
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'qbank-bank-'")).firstMatch
        XCTAssertTrue(named.appears(timeout: 5), app.debugDescription)
        attach(app, "free settings, share sheet open")
        XCTAssertFalse(app.staticTexts["settings.exportBank.problem"].exists)
    }
}
