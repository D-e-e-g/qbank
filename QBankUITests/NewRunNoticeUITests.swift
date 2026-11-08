import XCTest

/// A finished set opens at question 1 with a notice that answering starts a new run. The notice
/// is only words: nothing to tap, and answering goes on. Fake server, invented data. Runs on
/// iPhone and iPad.
final class NewRunNoticeUITests: XCTestCase {
    private static let notice = "You've answered this set before. Answering now starts a new practice run."

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// A set she has already finished opens at question 1 and says so. A set she has not started
    /// does not, and the notice leaves once she moves past question 1.
    @MainActor
    func testAFinishedSetOpensWithTheNewRunNotice() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 1", on: "Exam 1")
        let done = app.buttons["course.set.Rights, Law, and Ethics"]
        XCTAssertTrue(done.appears(timeout: 5))
        tapVisible(done, in: app)

        let notice = app.staticTexts["practice.newRun"]
        XCTAssertTrue(notice.appears(timeout: 5))
        XCTAssertEqual(notice.label, Self.notice)
        XCTAssertFalse(app.buttons["practice.newRun"].exists, "the notice has nothing to tap")
        XCTAssertFalse(app.staticTexts["practice.pickedUp"].exists)
        expectCount(app, "1 of 17")
        XCTAssertLessThanOrEqual(notice.frame.width, 720, "the notice stays in the reading column")
        XCTAssertGreaterThan(notice.frame.minX, -1)
        XCTAssertLessThan(notice.frame.maxX, app.frame.width + 1)
        attach(app, "finished set: the notice on question 1")

        // Answering is not blocked, and the notice stays while she is still on question 1.
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 10))
        XCTAssertEqual(notice.label, Self.notice)
        app.buttons["practice.next"].tap()
        XCTAssertTrue(notice.disappears(timeout: 5))
        expectCount(app, "2 of 17")
        attach(app, "finished set: question 2, the notice has left")

        // A set she has not started opens with no notice.
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.buttons["practice.close"].disappears(timeout: 5))
        goBack(app, from: "Week 1")
        goBack(app, from: "Exam 1")
        openFolder(app, "Weeks 1-3")
        let fresh = app.buttons["course.set.Mixed Clinical Judgment"]
        XCTAssertTrue(fresh.appears(timeout: 5))
        tapVisible(fresh, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        expectCount(app, "1 of 8")
        XCTAssertFalse(app.staticTexts["practice.newRun"].exists)
    }

    @MainActor
    private func expectCount(_ app: XCUIApplication, _ count: String) {
        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.appears(timeout: 5))
        let begins = NSPredicate(format: "label BEGINSWITH %@", count)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: begins, evaluatedWith: counter)], timeout: 5),
            .completed,
            "expected \(count), saw \(counter.label)"
        )
    }
}
