import XCTest

/// QBank Cloud for a free account: Settings' Cloud row, the plans sheet, a purchase that the server
/// turns into Cloud, the move of the bank on this iPhone to QBank Cloud that follows, the bank coming
/// back once Cloud ends, and the bank on this iPhone combined with the one QBank holds: on a second
/// device, for a returning subscriber, and on a new iPhone after Cloud ended. The App Store is the
/// fake store and the server the fake one, through the Debug launch seam, so nothing is bought and no
/// Apple Account is used. A unit test cannot do this job: it is the real sheet, as presented over
/// Settings, that must show each plan's name, period and price, the renewal terms and the two policy
/// links, and a real tap through StoreKit's stand-in to the server that must leave Settings saying
/// Cloud is on; and it is the real launch, the real Sign in with Apple screen and the real screens,
/// over the bank's files and the server's copy, that must show the bank's screen covering the app
/// until it ends, then every set where the bank is now: in QBank Cloud after a move or a combine, back
/// on this iPhone after Cloud ends, or combined on it. The sheet's tests run
/// on iPhone and iPad, where the sheet is the same and Settings is reached the same way; a test that
/// walks Home into a set runs on iPhone, where a course opens over Home.
final class CloudUITests: XCTestCase {
    private let topic = "Getting started"
    private let set = "General knowledge sampler"
    /// The topic of the invented sets a bank gains in QBank Cloud or on this iPhone.
    private let geography = "Geography"
    /// The name a returning subscriber gave that topic on this iPhone while Cloud was off.
    private let renamedGeography = "World geography"

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
        XCTAssertEqual(count(app, "sets").label, "Sets, 1")
        XCTAssertEqual(count(app, "questions").label, "Questions, 10")
        XCTAssertEqual(count(app, "answers").label, "Answers, 1")
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
        XCTAssertEqual(counted["cloudReturn.count.sets"].label, "Sets, 2")
        XCTAssertEqual(counted["cloudReturn.count.questions"].label, "Questions, 13")
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

    // MARK: Combining two banks

    /// A second device: this iPhone holds a bank from before the person had Cloud, and QBank Cloud
    /// holds their bank from another device. After Sign in with Apple the two are combined without a
    /// question: the screen covers the app while it runs, the first combined bank is refused because
    /// QBank Cloud's changed meanwhile and the combine starts again, and the outcome says what QBank
    /// Cloud holds now and what this iPhone added. The app then runs on QBank Cloud's bank, every set
    /// of both in it.
    @MainActor
    func testASecondDeviceCombinesItsBankWithCloud() throws {
        try skipOnIPad()
        let app = launch("cloud-second-device", environment: ["QB_UITEST_APPLE": "returning-person"])
        let apple = app.buttons["welcome.apple"]
        XCTAssertTrue(apple.appears(timeout: 10))
        apple.tap()

        let combining = app.staticTexts["cloudCombine.combining"]
        XCTAssertTrue(combining.appears(timeout: 10))
        XCTAssertEqual(combining.label, "Combining your banks")
        XCTAssertEqual(
            app.staticTexts["cloudCombine.lead"].label,
            "With QBank Cloud on, QBank keeps one bank for you. What is only on this iPhone is added to it. Nothing is removed.")
        XCTAssertEqual(app.staticTexts["cloudCombine.answers"].label, "Your answers from this iPhone are added too.")
        XCTAssertEqual(app.staticTexts["cloudCombine.safetyCopy"].label, "The bank on this iPhone stays on it, unchanged, as a safety copy.")
        XCTAssertEqual(app.staticTexts["cloudCombine.keepOpen"].label, "Keep QBank open. Your bank can't change until this ends.")
        let steps = app.descendants(matching: .any)
        XCTAssertEqual(steps["cloudCombine.step.reading"].label, "Reading your bank in QBank Cloud")
        XCTAssertEqual(steps["cloudCombine.step.combining"].label, "Combining it with the bank on this iPhone")
        XCTAssertEqual(steps["cloudCombine.step.sending"].label, "Sending what QBank Cloud does not have")
        XCTAssertEqual(steps["cloudCombine.step.checking"].label, "Checking that everything is there")
        let tab = tabButton(app, "Settings")
        XCTAssertFalse(tab.exists && tab.isHittable, "nothing in the app can change the bank while it is combined")
        attachLooks(app, "second device, combining")

        let combined = app.staticTexts["cloudCombine.combined"]
        XCTAssertTrue(combined.appears(timeout: 30))
        XCTAssertEqual(combined.label, "Your banks are combined")
        XCTAssertEqual(
            app.staticTexts["cloudCombine.body"].label,
            "QBank Cloud now holds everything from this iPhone and everything it already had. Nothing was removed.")
        XCTAssertEqual(combineCount(app, "sets").label, "Sets, 3", "the sample set is in both, and is one set")
        XCTAssertEqual(combineCount(app, "questions").label, "Questions, 15")
        XCTAssertEqual(combineCount(app, "answers").label, "Answers, 0")
        XCTAssertEqual(app.staticTexts["cloudCombine.added"].label, "Added from this iPhone: 1 set, 0 answers")
        XCTAssertFalse(app.staticTexts["cloudCombine.newerKept"].exists, "nothing was changed in both places")
        attachLooks(app, "second device, combined")
        app.buttons["cloudCombine.done"].tap()
        XCTAssertTrue(combined.disappears(timeout: 5))

        // QBank Cloud's bank, with its own set and the one this iPhone added beside it.
        openGeography(app)
        XCTAssertTrue(app.buttons["course.set.Invented capitals"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.set.Invented rivers"].exists)
        attach(app, "second device, the cloud bank")
        openTab(app, "Settings")
        waitForLabel(app.buttons["settings.cloud"], containing: "On")
        XCTAssertFalse(app.buttons["settings.combineBank"].exists, "nothing is left to combine")
        XCTAssertFalse(app.buttons["settings.moveToCloud"].exists)
        let saved = app.buttons["settings.savedForOffline"]
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists, "a bank in QBank Cloud is saved for offline")
    }

    /// A returning subscriber: this iPhone holds the bank that came back when Cloud ended, renamed a
    /// topic since and answers a question now. Buying Cloud again combines it with the bank QBank Cloud
    /// kept: the outcome says the newer change was kept, and the app then runs on QBank Cloud's bank,
    /// with the new name and the answer.
    @MainActor
    func testAReturningSubscriberKeepsItsNewerWork() throws {
        try skipOnIPad()
        let app = launch("cloud-returning-subscriber")

        // An answer on this iPhone while Cloud is off.
        let sample = openSampleSet(app)
        tapVisible(sample, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        tapVisible(app.buttons["practice.option.1"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
        app.buttons["practice.close"].tap()
        waitForLabel(sample, containing: "1 of 10 answered")
        openTab(app, "Home")
        XCTAssertTrue(app.buttons["home.topic.\(renamedGeography)"].appears(timeout: 10))

        openTab(app, "Settings")
        let cloud = app.buttons["settings.cloud"]
        XCTAssertTrue(cloud.appears(timeout: 5))
        XCTAssertFalse(app.buttons["settings.combineBank"].exists, "this iPhone took in the bank QBank holds")
        cloud.tap()
        let subscribe = app.buttons["cloud.plan.monthly.subscribe"]
        XCTAssertTrue(subscribe.appears(timeout: 5))
        subscribe.tap()

        let combined = app.staticTexts["cloudCombine.combined"]
        XCTAssertTrue(combined.appears(timeout: 30))
        XCTAssertEqual(combineCount(app, "sets").label, "Sets, 2")
        XCTAssertEqual(combineCount(app, "questions").label, "Questions, 13")
        XCTAssertEqual(combineCount(app, "answers").label, "Answers, 1")
        XCTAssertEqual(app.staticTexts["cloudCombine.added"].label, "Added from this iPhone: 0 sets, 1 answer")
        XCTAssertEqual(app.staticTexts["cloudCombine.newerKept"].label, "Where something was changed in both places, the newer change was kept.")
        attachLooks(app, "returning subscriber, combined")
        app.buttons["cloudCombine.done"].tap()
        XCTAssertTrue(combined.disappears(timeout: 5))

        // QBank Cloud's bank, with the newer name and the answer given here.
        openTab(app, "Home")
        XCTAssertTrue(app.buttons["home.topic.\(renamedGeography)"].appears(timeout: 10))
        XCTAssertFalse(app.buttons["home.topic.\(geography)"].exists, "the older name is not kept beside it")
        waitForLabel(openSampleSet(app), containing: "1 of 10 answered")
        openTab(app, "Settings")
        waitForLabel(app.buttons["settings.cloud"], containing: "On")
        let saved = app.buttons["settings.savedForOffline"]
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists, "the bank is in QBank Cloud")
    }

    /// A new iPhone for an account whose Cloud has ended: after Sign in with Apple the bank QBank holds
    /// is combined into the new bank, into a fresh file on this iPhone, with nothing sent. The first
    /// download loses the connection, which combines nothing and says so; trying again brings
    /// everything, and the app then runs on this iPhone with no connection at all.
    @MainActor
    func testANewIPhoneBringsDownALapsedBank() throws {
        try skipOnIPad()
        let app = launch("cloud-lapsed-new-iphone", environment: ["QB_UITEST_APPLE": "returning-person"])
        let apple = app.buttons["welcome.apple"]
        XCTAssertTrue(apple.appears(timeout: 10))
        apple.tap()

        let combining = app.staticTexts["cloudCombine.combining"]
        XCTAssertTrue(combining.appears(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["cloudCombine.step.sending"].exists, "nothing is sent to QBank")
        XCTAssertFalse(app.staticTexts["cloudCombine.lead"].exists, "QBank Cloud is not on")
        attachLooks(app, "new iPhone, combining")

        let failed = app.staticTexts["cloudCombine.failed"]
        XCTAssertTrue(failed.appears(timeout: 20))
        XCTAssertEqual(failed.label, "Your banks were not combined")
        XCTAssertEqual(app.staticTexts["cloudCombine.problem"].label, "The connection dropped before your whole bank arrived.")
        XCTAssertEqual(
            app.staticTexts["cloudCombine.unchanged"].label,
            "Nothing on this iPhone or in QBank Cloud was removed. You can keep using the bank on this iPhone.")
        attachLooks(app, "new iPhone, not combined")

        app.buttons["cloudCombine.retry"].tap()
        let combined = app.staticTexts["cloudCombine.combined"]
        XCTAssertTrue(combined.appears(timeout: 20))
        XCTAssertEqual(
            app.staticTexts["cloudCombine.body"].label,
            "Everything QBank held for you is on this iPhone, together with what was already here. Nothing in QBank was changed or deleted.")
        XCTAssertEqual(combineCount(app, "sets").label, "Sets, 2", "the sample set this iPhone filed is QBank's, and is one set")
        XCTAssertEqual(combineCount(app, "questions").label, "Questions, 13")
        XCTAssertFalse(app.staticTexts["cloudCombine.added"].exists)
        attachLooks(app, "new iPhone, combined")
        app.buttons["cloudCombine.done"].tap()
        XCTAssertTrue(combined.disappears(timeout: 5))

        // The bank is on this iPhone, with the set QBank held, and opens with no network.
        setNetwork(online: false)
        openGeography(app)
        XCTAssertTrue(app.buttons["course.set.Invented capitals"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["course.offline"].exists, "the bank is on this iPhone")
        attach(app, "new iPhone, the bank on this iPhone")
        openTab(app, "Settings")
        XCTAssertTrue(app.buttons["settings.cloud"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["settings.combineBank"].exists, "the bank QBank holds is on this iPhone")
    }

    /// The bank goes to QBank Cloud by a combine, back to this iPhone when Cloud ends, and to QBank
    /// Cloud again by a combine when Cloud is bought again: each switch keeps every set.
    @MainActor
    func testRepeatedSwitchesKeepEverySet() throws {
        try skipOnIPad()
        let app = launch("cloud-second-device", environment: ["QB_UITEST_APPLE": "returning-person"])
        let apple = app.buttons["welcome.apple"]
        XCTAssertTrue(apple.appears(timeout: 10))
        apple.tap()
        let combined = app.staticTexts["cloudCombine.combined"]
        XCTAssertTrue(combined.appears(timeout: 30))
        XCTAssertEqual(combineCount(app, "sets").label, "Sets, 3")
        app.buttons["cloudCombine.done"].tap()
        XCTAssertTrue(combined.disappears(timeout: 5))

        // Cloud ends, and the bank comes back to this iPhone once QBank says so.
        postDebugNotification("com.dimitrygallego.qbank.uitest.cloud.end")
        openTab(app, "Settings")
        let returned = app.staticTexts["cloudReturn.returned"]
        XCTAssertTrue(returned.appears(timeout: 30))
        let counted = app.descendants(matching: .any)
        XCTAssertEqual(counted["cloudReturn.count.sets"].label, "Sets, 3")
        XCTAssertEqual(counted["cloudReturn.count.questions"].label, "Questions, 15")
        app.buttons["cloudReturn.done"].tap()
        XCTAssertTrue(returned.disappears(timeout: 5))

        // Cloud is bought again: QBank Cloud holds the bank still, so the two are combined again. The
        // screens start afresh on the bank that came back.
        openTab(app, "Settings")
        let cloud = app.buttons["settings.cloud"]
        XCTAssertTrue(cloud.appears(timeout: 5))
        cloud.tap()
        let subscribe = app.buttons["cloud.plan.monthly.subscribe"]
        XCTAssertTrue(subscribe.appears(timeout: 5))
        subscribe.tap()
        XCTAssertTrue(combined.appears(timeout: 30))
        XCTAssertEqual(combineCount(app, "sets").label, "Sets, 3")
        XCTAssertEqual(combineCount(app, "questions").label, "Questions, 15")
        XCTAssertEqual(app.staticTexts["cloudCombine.added"].label, "Added from this iPhone: 0 sets, 0 answers", "everything was in both already")
        attach(app, "repeated switches, combined again")
        app.buttons["cloudCombine.done"].tap()
        XCTAssertTrue(combined.disappears(timeout: 5))

        openGeography(app)
        XCTAssertTrue(app.buttons["course.set.Invented capitals"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.set.Invented rivers"].exists)
        openTab(app, "Home")
        XCTAssertTrue(app.buttons["home.topic.\(topic)"].exists)
    }

    /// A combine of a new iPhone's bank with the one QBank holds that did not finish stays offered in
    /// Settings, also after QBank is closed and opened again, and runs from there.
    @MainActor
    func testALapsedBankIsStillOfferedAfterRelaunch() throws {
        try skipOnIPad()
        var app = launch("cloud-lapsed-new-iphone", environment: ["QB_UITEST_APPLE": "returning-person"])
        let apple = app.buttons["welcome.apple"]
        XCTAssertTrue(apple.appears(timeout: 10))
        apple.tap()
        let failed = app.staticTexts["cloudCombine.failed"]
        XCTAssertTrue(failed.appears(timeout: 20))
        app.buttons["cloudCombine.later"].tap()
        XCTAssertTrue(failed.disappears(timeout: 5))
        openTab(app, "Settings")
        var row = app.buttons["settings.combineBank"]
        XCTAssertTrue(row.appears(timeout: 10))
        XCTAssertTrue(row.label.contains("Bring my bank to this iPhone"), row.label)
        XCTAssertTrue(row.label.contains("QBank holds a bank for you that is not on this iPhone yet."), row.label)
        attachLooks(app, "lapsed, offered")

        // QBank is closed and opened again: the row is still there, and combines.
        app = launch("cloud-lapsed", keepPhoneData: true)
        openTab(app, "Settings")
        row = app.buttons["settings.combineBank"]
        XCTAssertTrue(row.appears(timeout: 10), "Settings keeps offering it after a relaunch")
        row.tap()
        let combined = app.staticTexts["cloudCombine.combined"]
        XCTAssertTrue(combined.appears(timeout: 20))
        XCTAssertEqual(combineCount(app, "sets").label, "Sets, 2")
        app.buttons["cloudCombine.done"].tap()
        XCTAssertTrue(combined.disappears(timeout: 5))
        XCTAssertFalse(app.buttons["settings.combineBank"].exists, "nothing is left to combine")
        openGeography(app)
        XCTAssertTrue(app.buttons["course.set.Invented capitals"].appears(timeout: 5))
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

    /// A count of the one bank a combine left, as its screen shows it, by what it counts.
    @MainActor
    private func combineCount(_ app: XCUIApplication, _ table: String) -> XCUIElement {
        app.descendants(matching: .any)["cloudCombine.count.\(table)"]
    }

    /// Opens the invented sets' folder from Home.
    @MainActor
    private func openGeography(_ app: XCUIApplication) {
        openTab(app, "Home")
        let card = app.buttons["home.topic.\(geography)"]
        XCTAssertTrue(card.appears(timeout: 10))
        card.tap()
        XCTAssertTrue(app.navigationBars[geography].appears(timeout: 5))
        tapVisible(app.buttons["folder.Unsorted"], in: app)
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
