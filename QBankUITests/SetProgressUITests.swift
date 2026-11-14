import XCTest

/// A practice set keeps her place: leaving a set midway and coming back opens it at the first
/// question she has not answered, whichever way she left. Fake server, invented data.
final class SetProgressUITests: XCTestCase {
    private static let set = "Mixed Clinical Judgment"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    /// The reproduction: she answers some of a set, leaves it, and comes back, by ✕ and by the app
    /// being killed. Today's app opened it at question 1 every time.
    @MainActor
    func testLeavingASetMidwayAndComingBackOpensAtTheFirstUnanswered() throws {
        let app = launch("signed-in")
        openSet(app, Self.set)
        expectCount(app, "1 of 8")
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists, "a set she has not begun has no line")
        answer(app, option: 0)
        next(app)
        answer(app, option: 1)
        next(app)
        expectCount(app, "3 of 8")

        // ✕, the row, and back in.
        app.buttons["practice.close"].tap()
        let row = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "2 of 8 answered · Continue")
        attach(app, "set progress: the row says Continue")
        attachLooks(app, "set progress: the row in each look")
        tapVisible(row, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        expectCount(app, "3 of 8")
        XCTAssertEqual(app.staticTexts["practice.pickedUp"].label, "Picked up at 3 · 2 answered earlier")
        attach(app, "set progress: it opens at question 3")
        attachLooks(app, "set progress: the line in each look")

        // The line stays with the question it picked up at.
        answer(app, option: 0)
        XCTAssertTrue(app.staticTexts["practice.pickedUp"].exists)
        next(app)
        expectCount(app, "4 of 8")
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)

        // The app is killed and opened again: QBank still knows.
        app.terminate()
        let again = launch("signed-in", keepServerAnswers: true)
        openSet(again, Self.set)
        expectCount(again, "4 of 8")
        XCTAssertEqual(again.staticTexts["practice.pickedUp"].label, "Picked up at 4 · 3 answered earlier")
    }

    @MainActor
    func testStartOverAsksOnceThenBeginsAgainAtQuestionOne() throws {
        let app = launch("signed-in")
        openSet(app, Self.set)
        answer(app, option: 0)
        next(app)
        app.buttons["practice.close"].tap()
        let row = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "1 of 8 answered · Continue")
        tapVisible(row, in: app)
        expectCount(app, "2 of 8")

        // It asks, and Cancel leaves her where she was.
        let startOver = app.buttons["practice.startOver"]
        XCTAssertTrue(startOver.appears(timeout: 5))
        startOver.tap()
        let question = app.staticTexts["practice.startOverSheet.title"]
        XCTAssertTrue(question.appears(timeout: 5))
        XCTAssertEqual(question.label, "Start over \(Self.set)?")
        XCTAssertEqual(app.staticTexts["practice.startOverSheet.message"].label, "Your 1 answer stays saved and still counts. The set begins again at question 1.")
        attach(app, "set progress: Start over asks once")
        attachLooks(app, "set progress: Start over in each look")
        app.buttons["practice.startOverSheet.cancel"].tap()
        XCTAssertTrue(question.disappears(timeout: 5))
        expectCount(app, "2 of 8")

        startOver.tap()
        XCTAssertTrue(question.appears(timeout: 5))
        app.buttons["practice.startOverSheet.confirm"].tap()
        XCTAssertTrue(app.staticTexts["practice.pickedUp"].disappears(timeout: 5))
        expectCount(app, "1 of 8")
        attach(app, "set progress: begun again at question 1")

        // Her answer stays: the row reads as it did before sittings, with nothing to continue.
        app.buttons["practice.close"].tap()
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "1 of 8 answered")
        XCTAssertFalse(row.label.contains("Continue"), row.label)
        tapVisible(row, in: app)
        expectCount(app, "1 of 8")
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)
    }

    /// The reproduction: on a slow connection an answer is picked, Start over is confirmed, and
    /// Check answer is tapped while Start over is still asking QBank. The score used to arrive
    /// after the set had begun again and land on the same question of the new run, shown answered
    /// with nothing picked. Now Check answer waits, so nothing of the previous run is sent.
    @MainActor
    func testCheckAnswerWaitsWhileStartOverIsOnItsWay() throws {
        let app = launch("slow-saves")
        openSet(app, Self.set)
        answer(app, option: 0)
        next(app)
        app.buttons["practice.close"].tap()
        let row = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "1 of 8 answered · Continue")
        tapVisible(row, in: app)
        expectCount(app, "2 of 8")
        tapVisible(app.buttons["practice.option.1"], in: app)
        let check = app.buttons["practice.check"]
        XCTAssertTrue(check.isEnabled)

        let startOver = app.buttons["practice.startOver"]
        startOver.tap()
        let confirm = app.buttons["practice.startOverSheet.confirm"]
        XCTAssertTrue(confirm.appears(timeout: 5))
        confirm.tap()
        // Start over is on its way for a few seconds: the question waits with it.
        XCTAssertTrue(check.appears(timeout: 2))
        XCTAssertFalse(check.isEnabled, "Check answer waits while Start over is asking QBank")
        XCTAssertFalse(startOver.isEnabled)
        // The tap that used to send the previous run's answer.
        check.tap()
        attach(app, "set progress: the question waits while Start over asks")

        expectCount(app, "1 of 8", timeout: 10)
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)
        tapVisible(app.buttons["practice.option.0"], in: app)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: check)], timeout: 10), .completed,
            "Check answer works again once the set has begun again"
        )
        check.tap()
        XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 10))
        next(app)

        // Question 2 of the new run, the one an answer was picked on, is open and untouched.
        expectCount(app, "2 of 8")
        XCTAssertTrue(check.appears(timeout: 5), "question 2 of the new run has no answer yet")
        XCTAssertFalse(check.isEnabled, "nothing is picked on it")
        XCTAssertFalse(app.descendants(matching: .any)["practice.feedback"].exists)
        attach(app, "set progress: the new run's question 2 is untouched")
    }

    /// A finished set still says how it went and opens fresh.
    @MainActor
    func testADoneSetOpensFreshAtQuestionOne() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 1", on: "Exam 1")
        let row = app.buttons["course.set.Rights, Law, and Ethics"]
        XCTAssertTrue(row.appears(timeout: 5))
        XCTAssertTrue(row.label.contains("Done "), row.label)
        XCTAssertTrue(row.label.contains("13 of 17 fully right"), row.label)
        XCTAssertFalse(row.label.contains("Continue"), row.label)
        attach(app, "set progress: a done set")
        tapVisible(row, in: app)
        expectCount(app, "1 of 17")
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)
    }

    /// A retake of a Done set leaves it Done, as the server says: the row never offers Continue, and
    /// the set opens at question 1 again, online, offline from the copy on the phone, and while her
    /// offline answer waits to be sent.
    @MainActor
    func testARetakeLeavesADoneSetDoneOnlineAndOffline() throws {
        let title = "Rights, Law, and Ethics"
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 1", on: "Exam 1")
        let row = app.buttons["course.set.\(title)"]
        XCTAssertTrue(row.appears(timeout: 5))
        XCTAssertTrue(row.label.contains("Done "), row.label)

        // Online: one answer begins a retake, and the row still says Done.
        tapVisible(row, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        expectCount(app, "1 of 17")
        answer(app, option: 0)
        next(app)
        expectCount(app, "2 of 17")
        app.buttons["practice.close"].tap()
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "Done today")
        XCTAssertFalse(row.label.contains("Continue"), row.label)
        attach(app, "set progress: a retake leaves the row Done")

        // It opens at question 1 again, and an answer made without signal waits on the phone.
        tapVisible(row, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        expectCount(app, "1 of 17")
        XCTAssertTrue(app.staticTexts["practice.newRun"].exists)
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)
        setNetwork(online: false)
        answer(app, option: 0)
        next(app)
        XCTAssertEqual(app.buttons["practice.waiting"].label, "1 waiting to send")

        // Her waiting answer counts, and the row still says Done.
        app.buttons["practice.close"].tap()
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "Done today")
        XCTAssertFalse(row.label.contains("Continue"), row.label)
        attach(app, "set progress: offline, a retake leaves the row Done")

        // The copy on the phone opens it at question 1, as the server would.
        tapVisible(row, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        expectCount(app, "1 of 17")
        XCTAssertTrue(app.staticTexts["practice.newRun"].exists)
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)
    }

    /// Day one: a set she is already midway through continues from the answers it has, with no row on
    /// the server yet, and says when she last answered.
    @MainActor
    func testASetMidwayOnTheFirstDayContinuesFromItsAnswers() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        let title = "Therapeutic Communication and the Relationship"
        let row = app.buttons["course.set.\(title)"]
        XCTAssertTrue(row.appears(timeout: 5))
        waitForLabel(row, containing: "9 of 14 answered · Continue")
        attach(app, "set progress: day one, the row")
        tapVisible(row, in: app)
        expectCount(app, "10 of 14")
        let line = app.staticTexts["practice.pickedUp"]
        XCTAssertTrue(line.label.hasPrefix("Picked up at 10 · last answered "), line.label)
        attach(app, "set progress: day one, it opens at question 10")
    }

    /// A Review answer to the first question of a Done set does not make it a retake.
    @MainActor
    func testAReviewAnswerLeavesADoneSetDone() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let tile = app.buttons["course.tile.review"]
        XCTAssertTrue(tile.appears(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))
        tapVisible(app.buttons["review.question.rights-v1-q0"], in: app)
        expectCount(app, "1 of 1")
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists, "Review has no sitting")
        answer(app, option: 0)
        next(app)
        XCTAssertTrue(app.staticTexts["result.title"].appears(timeout: 5))
        app.buttons["result.done"].tap()
        goBack(app, from: "Review")

        openFolder(app, "Week 1", on: "Exam 1")
        let row = app.buttons["course.set.Rights, Law, and Ethics"]
        XCTAssertTrue(row.appears(timeout: 5))
        XCTAssertTrue(row.label.contains("Done "), row.label)
        XCTAssertFalse(row.label.contains("Continue"), row.label)
    }

    /// A night without signal: her answers wait on the phone and count in her place, even after the
    /// app is killed, and Start over asks for a connection.
    @MainActor
    func testAnOfflineNightKeepsHerPlace() throws {
        let app = launch("signed-in")
        openSet(app, Self.set)
        setNetwork(online: false)
        answer(app, option: 0)
        next(app)
        answer(app, option: 1)
        next(app)
        expectCount(app, "3 of 8")
        XCTAssertEqual(app.buttons["practice.waiting"].label, "2 waiting to send")

        app.buttons["practice.close"].tap()
        let row = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "2 of 8 answered · Continue")
        attach(app, "set progress: offline, the row counts what waits")
        tapVisible(row, in: app)
        expectCount(app, "3 of 8")
        XCTAssertEqual(app.staticTexts["practice.pickedUp"].label, "Picked up at 3 · 2 answered earlier")

        app.buttons["practice.startOver"].tap()
        XCTAssertTrue(app.staticTexts["practice.startOverSheet.message"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["practice.startOverSheet.message"].label, "Your 2 answers stay saved and still count. The set begins again at question 1.")
        app.buttons["practice.startOverSheet.confirm"].tap()
        let problem = app.descendants(matching: .any)["problem"]
        XCTAssertTrue(problem.appears(timeout: 10))
        XCTAssertEqual(problem.label, "Could not start over. Check your connection and try again.")
        expectCount(app, "3 of 8")
        attach(app, "set progress: offline, Start over needs a connection")

        // The app is killed and opened again, still without signal.
        app.terminate()
        let again = launch("signed-in", keepPhoneData: true, online: false)
        let course = again.buttons["home.course.NURS 310"]
        XCTAssertTrue(course.appears(timeout: 10))
        course.tap()
        openFolder(again, "Weeks 1-3")
        let rowAgain = again.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(rowAgain.appears(timeout: 5))
        waitForLabel(rowAgain, containing: "2 of 8 answered · Continue")
        tapVisible(rowAgain, in: again)
        expectCount(again, "3 of 8")
        XCTAssertEqual(again.staticTexts["practice.pickedUp"].label, "Picked up at 3 · 2 answered earlier")
    }

    // MARK: Helpers

    @MainActor
    private func openSet(_ app: XCUIApplication, _ title: String, folder: String = "Weeks 1-3") {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "lands on NURS 310")
        openFolder(app, folder)
        let set = app.buttons["course.set.\(title)"]
        XCTAssertTrue(set.appears(timeout: 5))
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
    }

    @MainActor
    private func answer(_ app: XCUIApplication, option: Int) {
        tapVisible(app.buttons["practice.option.\(option)"], in: app)
        let check = app.buttons["practice.check"]
        XCTAssertTrue(check.isEnabled)
        check.tap()
        XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 10))
    }

    @MainActor
    private func next(_ app: XCUIApplication) {
        app.buttons["practice.next"].tap()
    }

    @MainActor
    private func expectCount(_ app: XCUIApplication, _ count: String, timeout: TimeInterval = 5) {
        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.appears(timeout: 5))
        let begins = NSPredicate(format: "label BEGINSWITH %@", count)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: begins, evaluatedWith: counter)], timeout: timeout), .completed, "expected \(count), saw \(counter.label)")
    }
}
