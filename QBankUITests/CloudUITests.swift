import XCTest

/// QBank Cloud for a free account: Settings' Cloud row, the plans sheet, a purchase that the server
/// turns into Cloud, and the move of the bank on this iPhone to QBank Cloud that follows. The App Store
/// is the fake store and the server the fake one, through the Debug launch seam, so nothing is bought
/// and no Apple Account is used. A unit test cannot do this job: it is the real sheet, as presented
/// over Settings, that must show each plan's name, period and price, the renewal terms and the two
/// policy links, and a real tap through StoreKit's stand-in to the server that must leave Settings
/// saying Cloud is on; and it is the real launch and the real screens, over the bank's file and the
/// server's copy, that must show the move covering the app until it ends and every set and answer in
/// QBank Cloud after it, or the bank still on this iPhone after a refusal. The sheet's tests run on
/// iPhone and iPad, where the sheet is the same and Settings is reached the same way; a test that
/// walks Home into a set runs on iPhone, where a course opens over Home.
final class CloudUITests: XCTestCase {
    private let topic = "Getting started"
    private let set = "General knowledge sampler"

    /// Each plan as the fake store sells it, as the StoreKit configuration file does: the key of its
    /// controls, its name, how long one payment lasts, and its price.
    private static let plans = [
        ("monthly", "QBank Cloud Monthly", "1 month, renews automatically", "$4.99"),
        ("yearly", "QBank Cloud Yearly", "1 year, renews automatically", "$29.99"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThePlansSheetShowsPricePeriodAndLegalLinks() {
        let app = launch("free-new-bank")
        let cloud = openCloudRow(app)
        waitForLabel(cloud, containing: "Off")
        cloud.tap()
        XCTAssertTrue(app.navigationBars["QBank Cloud"].appears(timeout: 5))

        for (key, name, period, price) in Self.plans {
            let shown = app.staticTexts["cloud.plan.\(key).name"]
            XCTAssertTrue(shown.appears(timeout: 5), key)
            XCTAssertEqual(shown.label, name)
            XCTAssertEqual(app.staticTexts["cloud.plan.\(key).period"].label, period)
            XCTAssertEqual(app.staticTexts["cloud.plan.\(key).price"].label, price)
            XCTAssertTrue(app.buttons["cloud.plan.\(key).subscribe"].isEnabled, key)
        }
        let renewal = app.staticTexts["cloud.autoRenew"]
        XCTAssertTrue(renewal.label.contains("renews automatically for the same period and price"), renewal.label)
        XCTAssertTrue(renewal.label.contains("at least 24 hours before the current period ends"), renewal.label)
        attach(app, "cloud plans sheet")

        let links = [
            ("cloud.privacy", "https://qbank-app.dimitrygallego.com/privacy"),
            ("cloud.terms", "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"),
        ]
        for (id, address) in links {
            let row = app.buttons[id]
            reveal(row, in: app)
            row.tap()
            let page = app.staticTexts["webpage.address"]
            XCTAssertTrue(page.appears(timeout: 5), id)
            XCTAssertEqual(page.label, address)
            app.buttons["webpage.done"].tap()
            XCTAssertTrue(page.disappears(timeout: 5), id)
        }
        XCTAssertTrue(app.buttons["cloud.restore"].exists)
    }

    @MainActor
    func testAPurchaseTurnsCloudOn() {
        let app = launch("free-new-bank")
        let cloud = openCloudRow(app)
        waitForLabel(cloud, containing: "Off")
        cloud.tap()

        let subscribe = app.buttons["cloud.plan.monthly.subscribe"]
        XCTAssertTrue(subscribe.appears(timeout: 5))
        subscribe.tap()

        // The server, not the store, says Cloud is on: the sheet closes and the new, empty bank moves.
        let moved = app.staticTexts["cloudMove.moved"]
        XCTAssertTrue(moved.appears(timeout: 15))
        XCTAssertTrue(app.navigationBars["QBank Cloud"].disappears(timeout: 5))
        app.buttons["cloudMove.done"].tap()
        XCTAssertTrue(moved.disappears(timeout: 5))

        // The sheet shows Cloud on in place of the plans.
        openTab(app, "Settings")
        waitForLabel(cloud, containing: "On")
        XCTAssertTrue(cloud.label.contains("Paid until"), cloud.label)
        attach(app, "settings with cloud on")
        cloud.tap()
        let active = app.descendants(matching: .any)["cloud.active"]
        XCTAssertTrue(active.appears(timeout: 10))
        XCTAssertTrue(active.label.contains("QBank Cloud is on"), active.label)
        XCTAssertTrue(app.staticTexts["cloud.paidUntil"].label.hasPrefix("Paid until "))
        XCTAssertEqual(app.staticTexts["cloud.bankPlace"].label, "Your bank is in QBank Cloud.")
        XCTAssertTrue(app.buttons["cloud.manage"].exists)
        XCTAssertFalse(app.buttons["cloud.plan.monthly.subscribe"].exists)
        XCTAssertFalse(app.buttons["cloud.move"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["problem"].exists)
        attach(app, "cloud on")
        app.buttons["cloud.done"].tap()
        XCTAssertTrue(app.navigationBars["QBank Cloud"].disappears(timeout: 5))
    }

    /// The bank on this iPhone, with an answer in it, moves to QBank Cloud after a purchase, and the
    /// app then shows the same set with the same answer from the server's copy.
    @MainActor
    func testMovingToCloudKeepsEverySetAndAnswer() throws {
        try skipOnIPad()
        let app = launch("free-first-launch")

        // An answer on this iPhone before the move.
        let sample = openSampleSet(app)
        tapVisible(sample, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        tapVisible(app.buttons["practice.option.1"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
        app.buttons["practice.close"].tap()
        waitForLabel(sample, containing: "1 of 10 answered")

        // Cloud turns on: the plans sheet closes and the move covers the app until it ends.
        openTab(app, "Settings")
        let cloud = app.buttons["settings.cloud"]
        XCTAssertTrue(cloud.appears(timeout: 5))
        waitForLabel(cloud, containing: "Off")
        cloud.tap()
        let subscribe = app.buttons["cloud.plan.monthly.subscribe"]
        XCTAssertTrue(subscribe.appears(timeout: 5))
        subscribe.tap()
        let moved = app.staticTexts["cloudMove.moved"]
        XCTAssertTrue(moved.appears(timeout: 15))
        XCTAssertEqual(moved.label, "Your bank is in QBank Cloud")
        XCTAssertTrue(count(app, "practiceSets").label.contains("1"), count(app, "practiceSets").label)
        XCTAssertTrue(count(app, "questions").label.contains("10"), count(app, "questions").label)
        XCTAssertTrue(count(app, "attempts").label.contains("1"), count(app, "attempts").label)
        XCTAssertTrue(app.staticTexts["cloudMove.safetyCopy"].label.contains("safety copy"))
        attachLooks(app, "moved to cloud")
        app.buttons["cloudMove.done"].tap()
        XCTAssertTrue(moved.disappears(timeout: 5))

        // The app runs on the server's copy, which has the set and the answer.
        let movedSample = openSampleSet(app)
        waitForLabel(movedSample, containing: "1 of 10 answered")
        attach(app, "the sample set in cloud")
        openTab(app, "Settings")
        waitForLabel(app.buttons["settings.cloud"], containing: "On")
        XCTAssertFalse(app.buttons["settings.moveToCloud"].exists)
        let saved = app.buttons["settings.savedForOffline"]
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists, "a bank in QBank Cloud is saved for offline, as any bank on the server")
    }

    /// The app was closed while its bank moved: at the next launch the move's screen comes first, runs
    /// the move again, and the app opens on the server's copy once it ends.
    @MainActor
    func testAMoveTheAppWasClosedDuringFinishesAtLaunch() throws {
        let app = launch("cloud-move-left-open")
        let moving = app.staticTexts["cloudMove.moving"]
        XCTAssertTrue(moving.appears(timeout: 10))
        XCTAssertEqual(moving.label, "Moving your bank to QBank Cloud")
        XCTAssertTrue(app.staticTexts["QBank was closed before the move ended, so it is moving your bank again from the start."].exists)
        XCTAssertEqual(app.descendants(matching: .any)["cloudMove.step.writing"].label, "Preparing a copy of your bank")
        let tab = tabButton(app, "Settings")
        XCTAssertFalse(tab.exists && tab.isHittable, "nothing in the app can change the bank while it moves")
        attachLooks(app, "move left open, moving")

        let moved = app.staticTexts["cloudMove.moved"]
        XCTAssertTrue(moved.appears(timeout: 15))
        attach(app, "move left open, moved")
        app.buttons["cloudMove.done"].tap()
        XCTAssertTrue(moved.disappears(timeout: 5))
        openTab(app, "Settings")
        waitForLabel(app.buttons["settings.cloud"], containing: "On")
        let saved = app.buttons["settings.savedForOffline"]
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists)
    }

    /// The server already holds a bank for the account and refuses the upload: the move's screen says
    /// so in the server's words, and the bank stays on this iPhone, which still offers the move.
    @MainActor
    func testARefusedMoveKeepsTheBankOnThisIPhone() throws {
        try skipOnIPad()
        let app = launch("cloud-move-refused")
        let failed = app.staticTexts["cloudMove.failed"]
        XCTAssertTrue(failed.appears(timeout: 10))
        XCTAssertEqual(failed.label, "Your bank stays on this iPhone")
        XCTAssertEqual(
            app.staticTexts["cloudMove.problem"].label,
            "This account already has a question bank on the server, so the upload was refused. Nothing was changed.")
        XCTAssertEqual(app.staticTexts["cloudMove.unchanged"].label, "Your bank on this iPhone is as it was, and you can keep using it.")
        XCTAssertFalse(app.buttons["cloudMove.retry"].exists, "the same upload would be refused again")
        XCTAssertEqual(app.buttons["cloudMove.later"].label, "OK")
        attachLooks(app, "move refused")
        app.buttons["cloudMove.later"].tap()
        XCTAssertTrue(failed.disappears(timeout: 5))

        let sample = openSampleSet(app)
        waitForLabel(sample, containing: "10")
        openTab(app, "Settings")
        let move = app.buttons["settings.moveToCloud"]
        XCTAssertTrue(move.appears(timeout: 10), "Cloud is on and the bank is still on this iPhone")
        XCTAssertFalse(app.buttons["settings.savedForOffline"].exists, "the bank is on this iPhone")
        attach(app, "move refused, settings")
    }

    /// Opens the sample set's folder from Home and returns the set's row.
    @MainActor
    private func openSampleSet(_ app: XCUIApplication) -> XCUIElement {
        openTab(app, "Home")
        let card = app.buttons["home.topic.\(topic)"]
        XCTAssertTrue(card.appears(timeout: 10))
        card.tap()
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        let folder = app.buttons["folder.Unsorted"]
        XCTAssertTrue(folder.appears(timeout: 5))
        tapVisible(folder, in: app)
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        let sample = app.buttons["course.set.\(set)"]
        XCTAssertTrue(sample.appears(timeout: 5))
        return sample
    }

    /// A count the moved screen shows, by the table it counts.
    @MainActor
    private func count(_ app: XCUIApplication, _ table: String) -> XCUIElement {
        app.descendants(matching: .any)["cloudMove.count.\(table)"]
    }

    /// Opens Settings on the free account's first screen and finds the Cloud row.
    @MainActor
    private func openCloudRow(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openTab(app, "Settings")
        let cloud = app.buttons["settings.cloud"]
        XCTAssertTrue(cloud.appears(timeout: 5))
        return cloud
    }
}
