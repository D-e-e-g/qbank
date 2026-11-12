import XCTest

/// Highlighting a question's words while answering it, against the in-process fake server of the
/// Debug launch seam: touch and hold a word, drag, lift, and the words take the pen's color; a tap
/// on a mark erases it; the pen at the top of the question picks yellow, blue or pink and holds
/// Clear highlights. Marks last for the attempt on this device and are never sent. Invented
/// questions and accounts only.
final class HighlightUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testMarkEraseRecolorAndClearInPractice() throws {
        let app = launch("signed-in")
        openSet(app)
        let stem = app.staticTexts["practice.stem"]
        XCTAssertTrue(stem.appears(timeout: 5))
        let pen = app.buttons["practice.pen"]
        XCTAssertTrue(pen.appears(timeout: 5))
        XCTAssertEqual(pen.value as? String, "Yellow", "the pen starts yellow")

        // Touch and hold a word, drag, lift: the words are marked in the pen's color.
        markWords(stem, from: 30, to: 230)
        waitForLabel(stem, valueContaining: "Yellow highlight: ")
        attachLooks(app, "highlight, stem marked")

        // A tap on the mark erases it.
        wordPoint(stem, 40).tap()
        expectNoMarks(stem)

        // The pen opens its colors beside it. Clear shows once the question has a mark.
        pen.tap()
        let blue = app.buttons["practice.pen.blue"]
        XCTAssertTrue(blue.appears(timeout: 5))
        XCTAssertFalse(app.buttons["practice.pen.clear"].exists, "nothing to clear yet")
        blue.tap()
        XCTAssertTrue(blue.disappears(timeout: 5), "picking a color closes the colors")
        XCTAssertEqual(pen.value as? String, "Blue")
        markWords(stem, from: 30, to: 230)
        waitForLabel(stem, valueContaining: "Blue highlight: ")

        // Dragging over a mark with another color repaints it.
        pen.tap()
        XCTAssertTrue(app.buttons["practice.pen.clear"].appears(timeout: 5))
        attachLooks(app, "highlight, pen open")
        app.buttons["practice.pen.pink"].tap()
        XCTAssertEqual(pen.value as? String, "Pink")
        markWords(stem, from: 30, to: 230)
        waitForLabel(stem, valueContaining: "Pink highlight: ")
        XCTAssertFalse((stem.value as? String ?? "").contains("Blue"), "the pink covers the blue")

        // On a choice, a drag marks its words and does not pick it; a plain tap still picks.
        let marked = app.buttons["practice.option.1"]
        reveal(marked, in: app)
        markWords(marked, from: 70, to: 230, line: 23)
        waitForLabel(marked, valueContaining: "Pink highlight: ")
        XCTAssertFalse(marked.isSelected, "marking a choice's words does not pick it")
        attachLooks(app, "highlight, choice marked")
        wordPoint(marked, 80, line: 23).tap()
        expectNoMarks(marked)
        XCTAssertFalse(marked.isSelected, "a tap on a mark erases it and does not pick the choice")
        markWords(marked, from: 70, to: 230, line: 23)
        waitForLabel(marked, valueContaining: "Pink highlight: ")
        let picked = app.buttons["practice.option.0"]
        tapVisible(picked, in: app)
        XCTAssertTrue(picked.isSelected, "a plain tap still picks")
        attachLooks(app, "highlight, choices")

        // Clear highlights takes every mark off the question.
        reveal(pen, in: app)
        pen.tap()
        let clear = app.buttons["practice.pen.clear"]
        XCTAssertTrue(clear.appears(timeout: 5))
        clear.tap()
        expectNoMarks(stem)
        expectNoMarks(marked)
        XCTAssertTrue(picked.isSelected, "clearing marks leaves her answer")

        // Marks stay after Check answer, beside the rationale, until the set is closed.
        markWords(stem, from: 30, to: 230)
        waitForLabel(stem, valueContaining: "Pink highlight: ")
        let check = app.buttons["practice.check"]
        XCTAssertTrue(check.isEnabled)
        check.tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
        XCTAssertTrue((stem.value as? String ?? "").contains("Pink highlight: "), "marks stay after Check answer")
        attachLooks(app, "highlight, checked")

        // The next question starts clean, and its table's cells are marked the same way.
        app.buttons["practice.next"].tap()
        let counter = app.staticTexts["practice.count"]
        let second = NSPredicate(format: "label BEGINSWITH %@", "2 of 8,")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: second, evaluatedWith: counter)], timeout: 5), .completed)
        expectNoMarks(app.staticTexts["practice.stem"])
        let reading = app.staticTexts["93%"]
        reveal(reading, in: app)
        markWords(reading, from: 4, to: 20, line: reading.frame.height / 2)
        waitForLabel(reading, valueContaining: "Pink highlight: 93%")
        attachLooks(app, "highlight, table")
    }

    @MainActor
    func testThePenKeepsItsColorAndMarksEndWithTheAttempt() throws {
        var app = launch("signed-in")
        openSet(app)
        let pen = app.buttons["practice.pen"]
        XCTAssertTrue(pen.appears(timeout: 5))
        pen.tap()
        let pink = app.buttons["practice.pen.pink"]
        XCTAssertTrue(pink.appears(timeout: 5))
        pink.tap()
        XCTAssertTrue(pink.disappears(timeout: 5), "picking a color closes the colors")
        XCTAssertEqual(pen.value as? String, "Pink")
        markWords(app.staticTexts["practice.stem"], from: 30, to: 230)
        waitForLabel(app.staticTexts["practice.stem"], valueContaining: "Pink highlight: ")

        app = launch("signed-in", keepPhoneSettings: true)
        openSet(app)
        XCTAssertTrue(app.buttons["practice.pen"].appears(timeout: 5))
        XCTAssertEqual(app.buttons["practice.pen"].value as? String, "Pink", "the pen keeps its color on this device")
        expectNoMarks(app.staticTexts["practice.stem"])
    }

    @MainActor
    func testMarksStayWithASkippedExamQuestion() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let tile = app.buttons["course.tile.exam"]
        XCTAssertTrue(tile.appears(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        let wrongOnly = app.switches["exam.wrongOnly"]
        XCTAssertTrue(wrongOnly.appears(timeout: 5))
        wrongOnly.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let week1 = app.buttons["exam.folder.Week 1"]
        waitForLabel(week1, containing: "4 wrong of 17")
        week1.tap()
        reveal(app.buttons["exam.start"], in: app)
        app.buttons["exam.start"].tap()
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10))

        let stem = app.staticTexts["practice.stem"]
        XCTAssertTrue(stem.appears(timeout: 5))
        markWords(stem, from: 30, to: 230)
        waitForLabel(stem, valueContaining: "Yellow highlight: ")
        attachLooks(app, "highlight, exam")
        for _ in 0..<4 {
            app.buttons["exam.skip"].tap()
        }
        let counter = app.staticTexts["practice.count"]
        let back = NSPredicate(format: "label BEGINSWITH %@", "1 of 4,")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: back, evaluatedWith: counter)], timeout: 5), .completed)
        reveal(stem, in: app)
        XCTAssertTrue((stem.value as? String ?? "").contains("Yellow highlight: "), "a skipped question keeps its marks")
    }

    // MARK: Helpers

    @MainActor
    private func openSet(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        let set = app.buttons["course.set.Mixed Clinical Judgment"]
        XCTAssertTrue(set.appears(timeout: 5))
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
    }

    /// A point on the text's first line, or on the line given, so many points in from its start.
    @MainActor
    private func wordPoint(_ element: XCUIElement, _ x: CGFloat, line y: CGFloat = 14) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// Touch and hold a word, drag along the line, lift.
    @MainActor
    private func markWords(_ element: XCUIElement, from: CGFloat, to: CGFloat, line y: CGFloat = 14) {
        wordPoint(element, from, line: y).press(forDuration: 0.7, thenDragTo: wordPoint(element, to, line: y))
    }

    @MainActor
    private func expectNoMarks(_ element: XCUIElement) {
        let clean = NSPredicate(format: "NOT (value CONTAINS %@)", "highlight")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: clean, evaluatedWith: element)], timeout: 5), .completed, "still marked: \(element.value ?? "")")
    }
}
