import XCTest

/// Exam twins (the Twin option of Exam setup) end to end against the fake server of the Debug launch
/// seam, whose twin jobs follow the server's rules and words and move one step on each time the app
/// reads them. Invented accounts, folders, and questions only.
final class TwinJobUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnlyTheAccountThatMayMakeQuestionsSeesTwin() throws {
        let app = launch("signed-in")
        openExamSetup(app)
        let week2 = app.buttons["exam.folder.Week 2"]
        XCTAssertTrue(week2.appears(timeout: 5))
        week2.tap()
        reveal(app.buttons["exam.start"], in: app)
        XCTAssertTrue(app.buttons["exam.start"].isEnabled)
        XCTAssertFalse(app.buttons["exam.twins.write"].exists, "no Twin option for an account that may not make questions")
        XCTAssertFalse(app.descendants(matching: .any)["exam.twins.offer"].exists)
    }

    @MainActor
    func testTwinsOfHerWrongQuestionsToTheExamOnThem() throws {
        let app = launch("maker", aiAllowed: true)
        openExamSetup(app)
        flip(app.switches["exam.wrongOnly"])
        let week2 = app.buttons["exam.folder.Week 2"]
        XCTAssertTrue(week2.appears(timeout: 5))
        week2.tap()
        let write = app.buttons["exam.twins.write"]
        reveal(write, in: app)
        XCTAssertTrue(write.isEnabled)
        XCTAssertEqual(
            app.staticTexts["exam.twins.offer"].label,
            "Or QBank writes a new exam twin of each wrong question in the folders you tick, and you take the exam on the twins. Your questions stay as they are."
        )
        attachLooks(app, "twins-1 exam setup, Week 2 wrong questions only")

        write.tap()
        XCTAssertTrue(app.navigationBars["Exam twins"].appears(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["twins.note"].label,
            "QBank writes exam twins of 7 wrong questions in Week 2. Once they are filed, exams over Week 2 ask only its exam twins."
        )
        waitForLabel(app.descendants(matching: .any)["twins.count"], containing: "7 exam twins")
        XCTAssertTrue(app.buttons["twins.stop"].exists, "Stop while it writes")
        // Each read moves the fake job one step on, so a count such as "3 of 7" shows for one poll:
        // wait for one before the screenshot, without failing on a slow run that read past it.
        _ = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'twins.step.twins' AND label CONTAINS ' of 7'"))
            .firstMatch.appears(timeout: 5)
        attachLooks(app, "twins-2 writing")

        let start = app.buttons["twins.start"]
        XCTAssertTrue(start.appears(timeout: 30), "the twins are filed")
        XCTAssertFalse(app.buttons["twins.stop"].exists)
        for key in ["read", "twins", "file"] {
            XCTAssertTrue(app.descendants(matching: .any)["twins.step.\(key)"].label.contains("Done"), key)
        }
        let filed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'twins.filed.'"))
        XCTAssertEqual(filed.count, 2)
        XCTAssertTrue(filed.element(boundBy: 0).label.contains("Therapeutic Communication and the Relationship exam"))
        XCTAssertTrue(filed.element(boundBy: 0).label.contains("Week 2 · 5 questions · Twins of Therapeutic Communication and the Relationship"))
        attachLooks(app, "twins-3 ready")

        // Found again from Exam setup, under Exam twins.
        goBack(app, from: "Exam twins")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'exam.twins.a0b2'")).firstMatch
        XCTAssertTrue(row.appears(timeout: 5))
        waitForLabel(row, containing: "Ready")
        XCTAssertTrue(row.label.contains("7 exam twins · Wrong questions only"), row.label)
        // The job was her third start today: the Twin option waits for tomorrow; the list stays.
        XCTAssertFalse(app.buttons["exam.twins.write"].exists)
        reveal(row, in: app)
        attachLooks(app, "twins-4 listed on exam setup")

        row.tap()
        XCTAssertTrue(app.navigationBars["Exam twins"].appears(timeout: 5))
        tapVisible(app.buttons["twins.start"], in: app)
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10), "the exam on the twins")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1 of 7'")).firstMatch.appears(timeout: 5), "7 questions: the twins")
        attachLooks(app, "twins-5 exam on the twins")
    }

    // A sheet over Exam setup that must keep the job from starting until Allow: only the running app
    // shows that no twin job opens first. The model's refusal to send without it is a unit test's.
    @MainActor
    func testTwinsAskBeforeAnythingIsSent() throws {
        let app = launch("maker")
        openExamSetup(app)
        let week2 = app.buttons["exam.folder.Week 2"]
        XCTAssertTrue(week2.appears(timeout: 5))
        week2.tap()
        let write = app.buttons["exam.twins.write"]
        tapVisible(write, in: app)

        let title = app.staticTexts["ai.permission.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["ai.permission.message"].label.contains("the practice questions you pick for exam twins"))
        XCTAssertFalse(app.navigationBars["Exam twins"].exists, "nothing started before Allow")
        attachLooks(app, "twins-0 permission")

        tapWhenStill(app.buttons["ai.permission.cancel"])
        XCTAssertTrue(title.disappears(timeout: 5))
        XCTAssertFalse(app.navigationBars["Exam twins"].exists, "Not now starts nothing")
        XCTAssertTrue(write.exists)
        XCTAssertTrue(write.isEnabled)

        tapVisible(write, in: app)
        XCTAssertTrue(title.appears(timeout: 5), "asked again")
        tapWhenStill(app.buttons["ai.permission.confirm"])
        XCTAssertTrue(app.navigationBars["Exam twins"].appears(timeout: 10), "Allow starts what she asked for")
    }

    @MainActor
    func testStopAsksFirst() throws {
        let app = launch("maker", aiAllowed: true)
        openExamSetup(app)
        // Every question of Week 2: 26 twins, so the job is still writing while she is asked.
        let week2 = app.buttons["exam.folder.Week 2"]
        XCTAssertTrue(week2.appears(timeout: 5))
        week2.tap()
        tapVisible(app.buttons["exam.twins.write"], in: app)
        let stop = app.buttons["twins.stop"]
        XCTAssertTrue(stop.appears(timeout: 5))

        stop.tap()
        XCTAssertEqual(app.staticTexts["twins.stopSheet.title"].appears(timeout: 5), true)
        XCTAssertEqual(app.staticTexts["twins.stopSheet.title"].label, "Stop the exam twins?")
        attachLooks(app, "twins-6 stop sheet")
        tapWhenStill(app.buttons["twins.stopSheet.cancel"])
        XCTAssertTrue(app.staticTexts["twins.stopSheet.title"].disappears(timeout: 5))
        XCTAssertTrue(stop.exists, "Keep going changes nothing")

        stop.tap()
        tapWhenStill(app.buttons["twins.stopSheet.confirm"])
        let stopped = app.staticTexts["twins.stopped"]
        XCTAssertTrue(stopped.appears(timeout: 5))
        XCTAssertEqual(stopped.label, "Stopped. Your questions stay as they are.")
        XCTAssertFalse(app.buttons["twins.start"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["twins.step.read"].label.contains("Cancelled") || app.descendants(matching: .any)["twins.step.twins"].label.contains("Cancelled"))
        attachLooks(app, "twins-7 stopped")
    }

    @MainActor
    func testARefusalShowsUntilSheChangesThePick() throws {
        let app = launch("maker", aiAllowed: true)
        openExamSetup(app)
        let week3 = app.buttons["exam.folder.Week 3"]
        XCTAssertTrue(week3.appears(timeout: 5))
        week3.tap()
        tapVisible(app.buttons["exam.twins.write"], in: app)
        let refusal = "Week 3 already has exam questions QBank can't match to its practice questions, so QBank leaves it as it is. Start the exam to take them."
        let problem = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", refusal)).firstMatch
        XCTAssertTrue(problem.appears(timeout: 5))
        XCTAssertFalse(app.navigationBars["Exam twins"].exists, "nothing started")
        attachLooks(app, "twins-8 refusal")

        tapVisible(week3, in: app)
        XCTAssertTrue(problem.disappears(timeout: 5), "the refusal was about Week 3")
    }

    // MARK: Helpers

    @MainActor
    private func openExamSetup(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let tile = app.buttons["course.tile.exam"]
        XCTAssertTrue(tile.appears(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
    }

    @MainActor
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.appears(timeout: 5))
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: flipped, evaluatedWith: toggle)], timeout: 5), .completed)
    }
}
