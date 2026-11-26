import XCTest

/// QBank Cloud for a free account: Settings' Cloud row, the plans sheet, a purchase that the server
/// turns into Cloud, the move of the bank on this iPhone to QBank Cloud that follows, the bank coming
/// back once Cloud ends, and a second device taking the bank QBank Cloud holds. The App Store is the
/// fake store and the server the fake one, through the Debug launch seam, so nothing is bought and no
/// Apple Account is used. A unit test cannot do this job: it is the real sheet, as presented over
/// Settings, that must show each plan's name, period and price, the renewal terms and the two policy
/// links, and a real tap through StoreKit's stand-in to the server that must leave Settings saying
/// Cloud is on; and it is the real launch, the real Sign in with Apple screen and the real screens,
/// over the bank's files and the server's copy, that must show the bank's screen covering the app
/// until it ends, then every set where the bank is now: in QBank Cloud after a move or on a second
/// device, back on this iPhone after Cloud ends, or still on it after a refusal. The sheet's tests run
/// on iPhone and iPad, where the sheet is the same and Settings is reached the same way; a test that
/// walks Home into a set runs on iPhone, where a course opens over Home.
final class CloudUITests: XCTestCase {
    private let topic = "Getting started"
    private let set = "General knowledge sampler"
    /// The topic of the invented sets a bank gains in QBank Cloud or on this iPhone.
    private let geography = "Geography"

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
        XCTAssertTrue(count(app, "sets").label.contains("1"), count(app, "sets").label)
        XCTAssertTrue(count(app, "questions").label.contains("10"), count(app, "questions").label)
        XCTAssertTrue(count(app, "answers").label.contains("1"), count(app, "answers").label)
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

    /// The server already holds a bank for the account, from another device, and refuses the upload:
    /// the app says what QBank Cloud holds and what only this iPhone has, and switches nothing on its
    /// own. Not now keeps the bank on this iPhone, and Settings offers QBank Cloud's bank in place of a
    /// move the server would refuse again.
    @MainActor
    func testARefusedMoveKeepsTheBankOnThisIPhone() throws {
        try skipOnIPad()
        let app = launch("cloud-move-refused")
        let found = app.staticTexts["cloudAdopt.found"]
        XCTAssertTrue(found.appears(timeout: 15))
        XCTAssertEqual(found.label, "QBank Cloud already has your bank")
        XCTAssertTrue(adoptCount(app, "sets").label.contains("1"), adoptCount(app, "sets").label)
        XCTAssertTrue(adoptCount(app, "questions").label.contains("3"), adoptCount(app, "questions").label)
        XCTAssertEqual(
            app.staticTexts["cloudAdopt.onlyHere"].label, "1 set only on this iPhone. Next, you can add it to QBank Cloud as a new set.")
        XCTAssertTrue(app.staticTexts["cloudAdopt.safetyCopy"].label.contains("safety copy"))
        attachLooks(app, "move refused, cloud bank found")
        app.buttons["cloudAdopt.later"].tap()
        XCTAssertTrue(found.disappears(timeout: 5))

        let sample = openSampleSet(app)
        waitForLabel(sample, containing: "10")
        openTab(app, "Settings")
        let use = app.buttons["settings.useCloudBank"]
        XCTAssertTrue(use.appears(timeout: 10), "Cloud is on and the bank is still on this iPhone")
        XCTAssertFalse(app.buttons["settings.moveToCloud"].exists, "QBank Cloud would refuse the same upload again")
        XCTAssertFalse(app.buttons["settings.savedForOffline"].exists, "the bank is on this iPhone")
        attach(app, "move refused, settings")
    }

    /// Cloud has ended for an account whose bank is in QBank Cloud: at launch the bank comes back to
    /// this iPhone, covering the app while it does. The first download loses the connection, which
    /// switches nothing and says so; trying again brings the whole bank back, with the set QBank Cloud
    /// gained since, and the app then runs on this iPhone with no connection at all.
    @MainActor
    func testCloudEndingHandsTheBankBack() throws {
        try skipOnIPad()
        let app = launch("cloud-ended")
        let returning = app.staticTexts["cloudReturn.returning"]
        XCTAssertTrue(returning.appears(timeout: 10))
        XCTAssertEqual(returning.label, "Bringing your bank back to this iPhone")
        XCTAssertEqual(app.descendants(matching: .any)["cloudReturn.step.downloading"].label, "Downloading your bank from QBank Cloud")
        let tab = tabButton(app, "Settings")
        XCTAssertFalse(tab.exists && tab.isHittable, "nothing in the app can change the bank while it comes back")
        attachLooks(app, "cloud ended, returning")

        // The first download loses the connection: nothing switches, and the screen says so.
        let failed = app.staticTexts["cloudReturn.failed"]
        XCTAssertTrue(failed.appears(timeout: 15))
        XCTAssertEqual(failed.label, "Your bank is still in QBank Cloud")
        XCTAssertEqual(app.staticTexts["cloudReturn.problem"].label, "The connection dropped before your whole bank arrived.")
        XCTAssertEqual(app.staticTexts["cloudReturn.unchanged"].label, "Nothing on this iPhone or in QBank Cloud was changed or deleted.")
        XCTAssertTrue(app.buttons["cloudReturn.later"].exists)
        attachLooks(app, "cloud ended, failed")

        app.buttons["cloudReturn.retry"].tap()
        XCTAssertTrue(returning.appears(timeout: 5))
        let returned = app.staticTexts["cloudReturn.returned"]
        XCTAssertTrue(returned.appears(timeout: 15))
        XCTAssertEqual(returned.label, "Your bank is on this iPhone")
        let counted = app.descendants(matching: .any)
        XCTAssertTrue(counted["cloudReturn.count.sets"].label.contains("2"), counted["cloudReturn.count.sets"].label)
        XCTAssertTrue(counted["cloudReturn.count.questions"].label.contains("13"), counted["cloudReturn.count.questions"].label)
        XCTAssertEqual(app.staticTexts["cloudReturn.cloudKept"].label, "Nothing was deleted from QBank Cloud.")
        attachLooks(app, "cloud ended, returned")
        app.buttons["cloudReturn.done"].tap()
        XCTAssertTrue(returned.disappears(timeout: 5))

        // The bank is on this iPhone now, with the set QBank Cloud gained, and opens with no network.
        setNetwork(online: false)
        openTab(app, "Home")
        let card = app.buttons["home.topic.\(geography)"]
        XCTAssertTrue(card.appears(timeout: 10), "the set QBank Cloud gained came back too")
        XCTAssertTrue(app.buttons["home.topic.\(topic)"].exists)
        card.tap()
        XCTAssertTrue(app.navigationBars[geography].appears(timeout: 5))
        tapVisible(app.buttons["folder.Unsorted"], in: app)
        XCTAssertTrue(app.buttons["course.set.Invented capitals"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["course.offline"].exists, "the bank is on this iPhone")
        attach(app, "cloud ended, the bank on this iPhone")
        openTab(app, "Settings")
        XCTAssertTrue(app.buttons["settings.cloud"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["settings.bringBankBack"].exists)
        XCTAssertFalse(app.buttons["settings.savedForOffline"].exists, "the bank is on this iPhone")
    }

    /// A second device: this iPhone holds a bank from before the person had Cloud, and QBank Cloud
    /// holds their bank from another device. After Sign in with Apple the app says what QBank Cloud
    /// holds and switches only on a tap; then it offers the set only this iPhone has, which goes to
    /// QBank Cloud as a new set only on a tap. The app then runs on QBank Cloud's bank, with that set in it.
    @MainActor
    func testASecondDeviceOpensTheCloudBank() throws {
        try skipOnIPad()
        let app = launch("cloud-second-device", environment: ["QB_UITEST_APPLE": "returning-person"])
        let apple = app.buttons["welcome.apple"]
        XCTAssertTrue(apple.appears(timeout: 10))
        apple.tap()

        let found = app.staticTexts["cloudAdopt.found"]
        XCTAssertTrue(found.appears(timeout: 15))
        XCTAssertTrue(adoptCount(app, "sets").label.contains("2"), adoptCount(app, "sets").label)
        XCTAssertTrue(adoptCount(app, "questions").label.contains("13"), adoptCount(app, "questions").label)
        XCTAssertEqual(
            app.staticTexts["cloudAdopt.onlyHere"].label, "1 set only on this iPhone. Next, you can add it to QBank Cloud as a new set.",
            "the sample set is in QBank Cloud already; only the set this iPhone made is not")
        attachLooks(app, "second device, cloud bank found")
        app.buttons["cloudAdopt.use"].tap()

        let offering = app.staticTexts["cloudAdopt.offering"]
        XCTAssertTrue(offering.appears(timeout: 10))
        XCTAssertEqual(offering.label, "1 set only on this iPhone")
        let offered = app.descendants(matching: .any)["cloudAdopt.set.Invented rivers"]
        XCTAssertTrue(offered.exists)
        XCTAssertTrue(offered.label.contains("Geography · Unsorted"), offered.label)
        XCTAssertEqual(app.buttons["cloudAdopt.add"].label, "Add it to QBank Cloud")
        attachLooks(app, "second device, offer")
        app.buttons["cloudAdopt.add"].tap()
        let added = app.staticTexts["cloudAdopt.added"]
        XCTAssertTrue(added.appears(timeout: 10))
        XCTAssertEqual(added.label, "Your set is in QBank Cloud")
        attach(app, "second device, added")
        app.buttons["cloudAdopt.done"].tap()
        XCTAssertTrue(added.disappears(timeout: 5))

        // QBank Cloud's bank, with its own set and the one this iPhone added beside it.
        openTab(app, "Home")
        let card = app.buttons["home.topic.\(geography)"]
        XCTAssertTrue(card.appears(timeout: 10))
        card.tap()
        XCTAssertTrue(app.navigationBars[geography].appears(timeout: 5))
        tapVisible(app.buttons["folder.Unsorted"], in: app)
        XCTAssertTrue(app.buttons["course.set.Invented capitals"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.set.Invented rivers"].exists)
        attach(app, "second device, the cloud bank")
        openTab(app, "Settings")
        waitForLabel(app.buttons["settings.cloud"], containing: "On")
        XCTAssertFalse(app.buttons["settings.addPhoneSets"].exists, "nothing is left to offer")
        let saved = app.buttons["settings.savedForOffline"]
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists, "a bank in QBank Cloud is saved for offline")
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

    /// A count the moved screen shows, by what it counts: sets, questions or answers.
    @MainActor
    private func count(_ app: XCUIApplication, _ table: String) -> XCUIElement {
        app.descendants(matching: .any)["cloudMove.count.\(table)"]
    }

    /// A count of QBank Cloud's bank, as the screen that offers it shows it, by what it counts.
    @MainActor
    private func adoptCount(_ app: XCUIApplication, _ table: String) -> XCUIElement {
        app.descendants(matching: .any)["cloudAdopt.count.\(table)"]
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
