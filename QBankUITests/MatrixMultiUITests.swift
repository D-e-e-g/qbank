import XCTest

/// A matrix where one row can fit more than one column: answering, the reveal, Review, and an
/// exam, on iPhone as cards and on iPad as a grid. Invented questions only, through the Debug
/// launch seam. The two tests run on different devices, so each one skips the other device.
final class MatrixMultiUITests: XCTestCase {
    private static let set = "Findings and Disorders"
    private static let longColumn = "Both volume problems written out so the header wraps"
    private static let little = "These fit too little fluid."
    private static let much = "These fit too much fluid."
    private static let either = "Weight can move either way."

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAnsweringRevealReviewAndExam() throws {
        try skipOnIPad()
        let app = launch("matrix-multi")
        practice(app, wide: false)
        review(app, wide: false)
        exam(app, wide: false)
    }

    @MainActor
    func testWideGridOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the wide grid is the iPad layout")
        let app = launch("matrix-multi")
        practice(app, wide: true)
        review(app, wide: true)
        exam(app, wide: true)
    }

    // MARK: Practice

    @MainActor
    private func practice(_ app: XCUIApplication, wide: Bool) {
        openSet(app)
        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.appears(timeout: 5))
        XCTAssertTrue(counter.label.hasPrefix("1 of 1"), counter.label)
        let meta = app.descendants(matching: .any)["practice.meta"]
        XCTAssertTrue(meta.label.hasPrefix("Matrix, check all that fit"), meta.label)
        let check = app.buttons["practice.check"]
        XCTAssertFalse(check.isEnabled, "nothing checked yet")

        tapBox(app, row: 0, column: "Hypovolemia")
        XCTAssertFalse(check.isEnabled, "two rows are still empty")
        tapBox(app, row: 1, column: "Hypervolemia")
        XCTAssertFalse(check.isEnabled, "one row is still empty")
        tapBox(app, row: 2, column: "Hypovolemia")
        XCTAssertTrue(check.isEnabled)
        tapBox(app, row: 2, column: "Hypovolemia")
        XCTAssertFalse(check.isEnabled, "clearing the last check on a row disables Check answer")
        tapBox(app, row: 2, column: "Hypovolemia")
        tapBox(app, row: 0, column: Self.longColumn)
        XCTAssertTrue(app.buttons[box(0, Self.longColumn)].isSelected)
        attach(app, wide ? "matrixmulti iPad, answering" : "matrixmulti iPhone, answering")
        expectFits(app, wide: wide)

        check.tap()
        let feedback = app.descendants(matching: .any)["practice.feedback"]
        XCTAssertTrue(feedback.appears(timeout: 5))
        XCTAssertTrue(feedback.label.contains("Partly correct"), feedback.label)
        XCTAssertTrue(feedback.label.contains("2 of 4 points"), feedback.label)
        XCTAssertTrue(feedback.label.contains("+1 for each correct box, -1 for each wrong one"), feedback.label)
        for reason in [Self.little, Self.much, Self.either] {
            let line = app.staticTexts[reason]
            reveal(line, in: app)
            XCTAssertTrue(line.exists, reason)
        }
        attach(app, wide ? "matrixmulti iPad, revealed" : "matrixmulti iPhone, revealed")
        expectFits(app, wide: wide)
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Weeks 1-3"].appears(timeout: 5))
        goBack(app, from: "Weeks 1-3")
    }

    // MARK: Review

    @MainActor
    private func review(_ app: XCUIApplication, wide: Bool) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5))
        app.buttons["course.tile.review"].tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))
        let row = app.buttons["review.question.findings-v1-q0"]
        tapVisible(row, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.meta"].label.hasPrefix("Matrix, check all that fit"))
        XCTAssertFalse(app.buttons["practice.check"].isEnabled, "Review opens the question to answer again")
        answerTheMix(app)
        app.buttons["practice.check"].tap()
        let feedback = app.descendants(matching: .any)["practice.feedback"]
        XCTAssertTrue(feedback.appears(timeout: 5))
        XCTAssertTrue(feedback.label.contains("2 of 4 points"), feedback.label)
        reveal(app.staticTexts[Self.either], in: app)
        attach(app, wide ? "matrixmulti iPad, review" : "matrixmulti iPhone, review")
        expectFits(app, wide: wide)
        app.buttons["practice.next"].tap()
        XCTAssertTrue(app.staticTexts["result.title"].appears(timeout: 5))
        app.buttons["result.done"].tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))
        goBack(app, from: "Review")
    }

    // MARK: Exam

    @MainActor
    private func exam(_ app: XCUIApplication, wide: Bool) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5))
        app.buttons["course.tile.exam"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        let folder = app.buttons["exam.folder.Weeks 1-3"]
        tapVisible(folder, in: app)
        let start = app.buttons["exam.start"]
        reveal(start, in: app)
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: start)], timeout: 10), .completed)
        start.tap()
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10))
        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.label.hasPrefix("1 of 1"), counter.label)
        XCTAssertTrue(app.staticTexts["practice.meta"].label.hasPrefix("Matrix, check all that fit"))
        XCTAssertFalse(app.buttons["exam.submit"].isEnabled)
        answerTheMix(app)
        let submit = app.buttons["exam.submit"]
        XCTAssertEqual(submit.label, "Finish exam")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let title = app.staticTexts["examResult.title"]
        XCTAssertTrue(title.appears(timeout: 10))
        let question = app.buttons["examResult.question.1"]
        reveal(question, in: app)
        XCTAssertTrue(question.label.contains("Matrix, check all that fit"), question.label)
        XCTAssertTrue(question.label.contains("2 of 4"), question.label)
        tapVisible(question, in: app)
        XCTAssertEqual(question.value as? String, "Expanded")
        let reason = app.staticTexts[Self.either]
        reveal(reason, in: app)
        XCTAssertTrue(reason.exists)
        attach(app, wide ? "matrixmulti iPad, exam result" : "matrixmulti iPhone, exam result")
        expectFits(app, wide: wide)
    }

    /// The mix that shows every reveal state and scores 2 of 4: a wrong box, a missed box, and the rest right.
    @MainActor
    private func answerTheMix(_ app: XCUIApplication) {
        tapBox(app, row: 0, column: "Hypovolemia")
        tapBox(app, row: 0, column: Self.longColumn)
        tapBox(app, row: 1, column: "Hypervolemia")
        tapBox(app, row: 2, column: "Hypovolemia")
    }

    @MainActor
    private func openSet(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        let set = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(set.appears(timeout: 5))
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
    }

    @MainActor
    private func tapBox(_ app: XCUIApplication, row: Int, column: String) {
        tapVisible(app.buttons[box(row, column)], in: app)
    }

    private func box(_ row: Int, _ column: String) -> String {
        "practice.matrixmulti.\(row).\(column)"
    }

    /// Long text stays inside the window, and on iPad the check cells are 44 points and line up with the header.
    @MainActor
    private func expectFits(_ app: XCUIApplication, wide: Bool) {
        let window = app.windows.firstMatch.frame
        let stem = app.staticTexts["practice.stem"]
        if stem.exists { expectInside(stem, window: window) }
        let longBox = app.buttons[box(0, Self.longColumn)]
        if longBox.exists {
            reveal(longBox, in: app)
            expectInside(longBox, window: window)
        }
        guard wide else {
            let shortBox = app.buttons[box(0, "Hypovolemia")]
            if longBox.exists, shortBox.exists {
                XCTAssertGreaterThan(longBox.frame.height, shortBox.frame.height, "a long column name wraps inside its pill")
            }
            return
        }
        let header = app.staticTexts["practice.matrixmulti.column.\(Self.longColumn)"]
        let shortHeader = app.staticTexts["practice.matrixmulti.column.Hypovolemia"]
        let cell = app.buttons[box(0, "Hypovolemia")]
        let longCell = app.buttons[box(0, Self.longColumn)]
        reveal(header, in: app)
        reveal(cell, in: app)
        reveal(longCell, in: app)
        expectInside(header, window: window)
        expectInside(cell, window: window)
        expectInside(longCell, window: window)
        XCTAssertGreaterThan(header.frame.height, shortHeader.frame.height, "a long column name wraps in the header")
        XCTAssertEqual(cell.frame.width, 44, accuracy: 1)
        XCTAssertEqual(cell.frame.height, 44, accuracy: 1)
        XCTAssertEqual(header.frame.midX, app.buttons[box(0, Self.longColumn)].frame.midX, accuracy: 2)
        XCTAssertEqual(shortHeader.frame.midX, cell.frame.midX, accuracy: 2)
    }

    @MainActor
    private func expectInside(_ element: XCUIElement, window: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty, element.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 1, element.identifier, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1, element.identifier, file: file, line: line)
    }
}
