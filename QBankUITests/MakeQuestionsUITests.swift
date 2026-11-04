import XCTest

/// Make questions (Q-1 to Q-6 and Q-2b) end to end against the fake server of the Debug launch
/// seam, whose question maker follows the server's rules and words and moves a set one step on
/// each time the app reads it. Invented accounts and material only.
final class MakeQuestionsUITests: XCTestCase {
    static let writingJob = "a0b10000-0000-4000-8000-000000000001"
    static let copyJob = "a0b10000-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnlyTheAccountTheServerAllowsSeesMakeQuestions() throws {
        let app = launch("signed-in")
        openAdd(app)
        XCTAssertTrue(app.buttons["add.import"].exists)
        let note = "Making questions is not available on this account. Import works on every account."
        XCTAssertTrue(app.staticTexts[note].appears(timeout: 5), "the server's words")
        XCTAssertFalse(app.buttons["add.make"].exists, "Import only")
        attachLooks(app, "Q-1 add, import only")
    }

    @MainActor
    func testAServerNotSetUpSaysSoInItsWords() throws {
        let app = launch("maker-not-set-up")
        openAdd(app)
        XCTAssertTrue(app.staticTexts["Making questions is not set up yet."].appears(timeout: 5))
        XCTAssertFalse(app.buttons["add.make"].exists, "Make questions shows only when the server says it is available")
        XCTAssertTrue(app.buttons["add.import"].exists)
        attachLooks(app, "Q-1 add, not set up")
    }

    @MainActor
    func testMakeASetFromPastedNotes() throws {
        let app = launch("maker")
        openAdd(app)
        let make = app.buttons["add.make"]
        XCTAssertTrue(make.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 of 3 sets left today"].exists)
        let writing = app.buttons["add.job.\(Self.writingJob)"]
        XCTAssertTrue(writing.exists)
        XCTAssertTrue(writing.label.contains("Schizophrenia and Antipsychotics"))
        XCTAssertTrue(writing.label.contains("NURS 310 · Week 4 · 9 of 15 written"))
        attachLooks(app, "Q-1 add")

        make.tap()
        XCTAssertTrue(app.navigationBars["Your material"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].exists)
        XCTAssertTrue(app.buttons["Photos"].isSelected)
        XCTAssertTrue(app.buttons["make.holding.notes"].isSelected)
        waitForLabel(app.buttons["import.course"], containing: "NURS 310 · Mental Health")
        attachLooks(app, "Q-2 material")

        app.buttons["Paste"].tap()
        let notes = app.textViews["make.notes"]
        XCTAssertTrue(notes.appears(timeout: 5))
        notes.tap()
        notes.typeText("Invented notes on antipsychotics.")
        tapVisible(app.buttons["make.next"], in: app)

        XCTAssertTrue(app.navigationBars["Level and count"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["Exam"].isSelected, "her recipe's default")
        XCTAssertTrue(app.staticTexts["15 questions"].exists)
        XCTAssertTrue(app.staticTexts["About 20 minutes to write"].exists)
        attachLooks(app, "Q-3 level and count")
        tapVisible(app.buttons["make.start"], in: app)

        XCTAssertTrue(app.navigationBars["Check 5 samples"].appears(timeout: 20))
        XCTAssertTrue(app.staticTexts["Step 3 of 4"].exists)
        let third = app.buttons["make.sample.3.verdict"]
        XCTAssertTrue(third.exists)
        XCTAssertTrue(third.label.contains("Not checked"))
        attachLooks(app, "Q-4 samples")

        // A sample opens in the runner, to answer like practice.
        app.buttons["make.sample.1"].tap()
        let close = app.buttons["practice.close"]
        XCTAssertTrue(close.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample 1"].exists)
        close.tap()

        third.tap()
        app.buttons["Change"].tap()
        let note = app.textViews["make.sample.3.note"].exists ? app.textViews["make.sample.3.note"] : app.textFields["make.sample.3.note"]
        XCTAssertTrue(note.appears(timeout: 5))
        note.typeText("Make the stem about day 3 of haloperidol.")
        attachLooks(app, "Q-4 samples, one to change")
        tapVisible(app.buttons["make.writeRest"], in: app)

        XCTAssertTrue(app.navigationBars["Writing your set"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["Step 4 of 4"].exists)
        attachLooks(app, "Q-5 writing")

        let done = app.staticTexts["make.done.title"]
        XCTAssertTrue(done.appears(timeout: 60))
        XCTAssertEqual(done.label, "Your set is ready")
        XCTAssertEqual(app.staticTexts["make.done.copy"].label, "“Unsorted Practice” · 15 questions in NURS 310, Unsorted.")
        XCTAssertTrue(app.staticTexts["14 of 15 passed the blind check · 1 fixed"].exists)
        XCTAssertTrue(app.staticTexts["15 exam twins in the Unsorted exam bank"].exists)
        attachLooks(app, "Q-6 finished")

        app.buttons["make.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        XCTAssertTrue(tabButton(app, "Home").isSelected)
    }

    @MainActor
    func testCheckTheQuestionsCopiedFromPhotos() throws {
        let app = launch("maker")
        openAdd(app)
        let copies = app.buttons["add.job.\(Self.copyJob)"]
        XCTAssertTrue(copies.appears(timeout: 5))
        XCTAssertTrue(copies.label.contains("NURS 310 · Week 3 · Questions to check"))
        copies.tap()

        XCTAssertTrue(app.navigationBars["3 questions found"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["Check the copies"].exists)
        XCTAssertTrue(app.buttons["make.copy.1"].label.contains("Answer from the photo: A"))
        XCTAssertTrue(app.buttons["make.copy.3"].label.contains("No answer in the photo · QBank suggests A, check it"))
        XCTAssertTrue(app.staticTexts["The bottom of photo 2 is blurry."].exists)
        attachLooks(app, "Q-2b copies")

        app.buttons["make.copy.3"].tap()
        XCTAssertTrue(app.navigationBars["Question 3"].appears(timeout: 5))
        app.buttons["make.copy.choice.B"].tap()
        attachLooks(app, "Q-2b one copy")
        app.buttons["make.copy.use"].tap()
        waitForLabel(app.buttons["make.copy.3"], containing: "Your answer: B")

        app.buttons["make.copy.2"].tap()
        XCTAssertTrue(app.buttons["make.copy.skip"].appears(timeout: 5))
        app.buttons["make.copy.skip"].tap()
        waitForLabel(app.buttons["make.copy.2"], containing: "Left out")

        let add = app.buttons["make.addCopies"]
        reveal(add, in: app)
        XCTAssertEqual(add.label, "Add 2 questions to Week 3")
        add.tap()
        let done = app.staticTexts["make.done.title"]
        XCTAssertTrue(done.appears(timeout: 30))
        XCTAssertTrue(app.staticTexts["2 questions checked by you"].exists)
        attachLooks(app, "Q-6 copies finished")
    }

    @MainActor
    func testStoppingASetTakesItOffInProgress() throws {
        let app = launch("maker")
        openAdd(app)
        let writing = app.buttons["add.job.\(Self.writingJob)"]
        XCTAssertTrue(writing.appears(timeout: 5))
        writing.tap()
        XCTAssertTrue(app.navigationBars["Writing your set"].appears(timeout: 10))
        app.buttons["make.more"].tap()
        chooseFromMenu(menuItem(app, "make.stop", "Stop making this set"))
        // The dialog's action carries its identifier on both its outer and its inner button.
        let confirm = app.buttons["make.stop.confirm"].firstMatch
        XCTAssertTrue(confirm.appears(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Add questions"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["add.job.\(Self.writingJob)"].appears(timeout: 2))
        XCTAssertTrue(app.buttons["add.job.\(Self.copyJob)"].exists)
    }

    @MainActor
    private func openAdd(_ app: XCUIApplication) {
        openTab(app, "Add", timeout: 10)
        XCTAssertTrue(app.navigationBars["Add questions"].appears(timeout: 5))
    }
}
