import XCTest

/// Where an exam starts and ends: an end that does not go through at once keeps its one button
/// until the server confirms it, and a start over a running exam asks first and names it.
final class ExamLifecycleUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    /// Her last answer lands and the finish after it loses the connection. The runner offers only
    /// Finish exam, not the answered question; once the finish goes through, the exam is recorded finished, with her minutes.
    @MainActor
    func testAFinishThatDoesNotGoThroughWaitsForItsButton() throws {
        let app = launch("exam-finish-drops")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        app.buttons["course.tile.exam"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        let resume = app.buttons["exam.resume"]
        XCTAssertTrue(resume.appears(timeout: 10))
        resume.tap()

        let submit = app.buttons["exam.submit"]
        XCTAssertTrue(submit.appears(timeout: 10))
        XCTAssertEqual(submit.label, "Finish exam", "the last question still open")
        tapVisible(app.buttons["practice.option.0"], in: app)
        submit.tap()

        // The answer is in; the finish is not.
        let note = app.staticTexts["exam.pendingEnd"]
        XCTAssertTrue(note.appears(timeout: 10))
        XCTAssertTrue(note.label.hasSuffix("questions answered. Finish the exam to see your result."), note.label)
        XCTAssertEqual(app.descendants(matching: .any)["problem"].label, "Could not end the exam. Check the connection; QBank keeps trying.")
        XCTAssertTrue(app.buttons["exam.finishPending"].exists)
        XCTAssertEqual(app.buttons["exam.finishPending"].label, "Finish exam")
        XCTAssertFalse(submit.exists, "no Submit and continue on an answered question")
        XCTAssertFalse(app.buttons["exam.skip"].exists)
        XCTAssertTrue(app.buttons["exam.end"].exists, "End exam stays in the top bar, the way out")
        XCTAssertTrue(app.descendants(matching: .any)["exam.timer"].exists, "the exam still runs")
        attach(app, "exam, finish not confirmed")

        // The connection comes back: Finish exam, or the runner's next try, ends it as finished.
        let finish = app.buttons["exam.finishPending"]
        let title = app.staticTexts["examResult.title"]
        let enabled = NSPredicate(format: "isEnabled == true")
        if XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: finish)], timeout: 20) == .completed, finish.exists {
            finish.tap()
        }
        XCTAssertTrue(title.appears(timeout: 40))
        let points = app.staticTexts["examResult.points"].label
        XCTAssertFalse(points.contains("Ended early"), points)
        XCTAssertFalse(points.contains("Time ran out"), points)
        attach(app, "exam result, finished after the connection came back")
        app.buttons["examResult.done"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        XCTAssertTrue(resume.disappears(timeout: 10), "nothing is running")
    }

    /// Starting an exam while one runs asks first, and the exam she agreed to end is the one that
    /// ends, as left; the new one opens.
    @MainActor
    func testStartingOverARunningExamAsksAndEndsThatOne() throws {
        let app = launch("exam-in-progress")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        app.buttons["course.tile.exam"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["exam.resume"].appears(timeout: 10))
        let week3 = app.buttons["exam.folder.Week 3"]
        reveal(week3, in: app)
        week3.tap()
        let start = app.buttons["exam.start"]
        reveal(start, in: app)
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: start)], timeout: 10), .completed)
        start.tap()

        let title = app.staticTexts["exam.replaceSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Start a new exam?")
        attach(app, "start a new exam over the running one")
        let confirm = app.buttons["exam.replaceSheet.confirm"]
        XCTAssertTrue(confirm.appears(timeout: 5))
        confirm.tap()

        let end = app.buttons["exam.end"]
        XCTAssertTrue(end.appears(timeout: 10), "the new exam opens")
        XCTAssertTrue(app.staticTexts["practice.count"].label.contains("Exam · Week 3"), app.staticTexts["practice.count"].label)
        end.tap()
        let sure = app.buttons["exam.endSheet.confirm"]
        XCTAssertTrue(sure.appears(timeout: 5))
        sure.tap()
        XCTAssertTrue(app.staticTexts["examResult.title"].appears(timeout: 10))
        app.buttons["examResult.done"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["exam.resume"].exists, "both exams ended")
        let pastWeeks12 = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exam.past.' AND label CONTAINS 'Weeks 1-2' AND label CONTAINS 'Ended early'")).firstMatch
        reveal(pastWeeks12, in: app)
        XCTAssertTrue(pastWeeks12.exists, "the exam she agreed to end ended as left")
    }
}
