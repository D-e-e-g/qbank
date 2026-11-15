import XCTest

/// Marking with no hold first, on iPhone and on iPad, against the in-process fake server of the
/// Debug launch seam: a finger's swipe along the words marks them at once, a swipe up or down
/// scrolls even when it starts on words, and a swipe that starts beside the words scrolls. The
/// pen's menu holds an eraser, which takes marks off by swipe and by tap, and Clear highlights.
/// XCTest cannot make an Apple Pencil's touch; `HighlightSwipeTests` covers the Pencil. Invented
/// questions and accounts only.
final class HighlightSwipeUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    @MainActor
    func testASwipeAlongTheWordsMarksAtOnce() throws {
        let app = launch("signed-in")
        openSet(app)
        let stem = app.staticTexts["practice.stem"]
        let pen = app.buttons["practice.pen"]
        XCTAssertEqual(pen.value as? String, "Yellow", "the pen starts yellow")

        // Left to right along the first line, with no hold and without opening the pen.
        let before = stem.frame
        swipe(from: point(stem, 30), to: point(stem, 230))
        waitForLabel(stem, valueContaining: "Yellow highlight: ")
        XCTAssertEqual(stem.frame, before, "marking does not move the page")
        attachLooks(app, "swipe, stem marked")

        // Right to left, on the ask.
        let ask = app.staticTexts["practice.ask"]
        swipe(from: point(ask, 200, line: 12), to: point(ask, 20, line: 12))
        waitForLabel(ask, valueContaining: "Yellow highlight: ")

        // On a choice, a swipe marks its words and does not pick it; a plain tap still picks.
        let choice = app.buttons["practice.option.1"]
        reveal(choice, in: app)
        swipe(from: point(choice, 70, line: 23), to: point(choice, 230, line: 23))
        waitForLabel(choice, valueContaining: "Yellow highlight: ")
        XCTAssertFalse(choice.isSelected, "marking a choice's words does not pick it")
        point(choice, 150, line: choice.frame.height - 6).tap()
        waitForSelected(choice)
        reveal(pen, in: app)
        attachLooks(app, "swipe, choice marked")

        // Clear highlights takes every mark off the question, and leaves the answer.
        pen.tap()
        let clear = app.buttons["practice.pen.clear"]
        XCTAssertTrue(clear.appears(timeout: 5))
        clear.tap()
        expectNoMarks(stem)
        expectNoMarks(ask)
        expectNoMarks(choice)
        XCTAssertTrue(choice.isSelected, "clearing marks leaves the answer")
    }

    @MainActor
    func testTheEraserTakesMarksOffBySwipeAndByTap() throws {
        var app = launch("signed-in")
        openSet(app)
        let stem = app.staticTexts["practice.stem"]
        let pen = app.buttons["practice.pen"]
        swipe(from: point(stem, 30), to: point(stem, 230))
        waitForLabel(stem, valueContaining: "Yellow highlight: ")
        let whole = try XCTUnwrap(stem.value as? String)

        // The eraser sits after the colors, before Clear highlights.
        pen.tap()
        let eraser = app.buttons["practice.pen.eraser"]
        XCTAssertTrue(eraser.appears(timeout: 5))
        XCTAssertFalse(eraser.isSelected)
        XCTAssertTrue(app.buttons["practice.pen.yellow"].isSelected)
        XCTAssertGreaterThan(eraser.frame.minX, app.buttons["practice.pen.pink"].frame.maxX - 1, "after the colors")
        XCTAssertLessThan(eraser.frame.maxX, app.buttons["practice.pen.clear"].frame.minX + 1, "before Clear highlights")
        attachLooks(app, "eraser, pen open")
        eraser.tap()
        XCTAssertTrue(eraser.disappears(timeout: 5), "choosing the eraser closes the menu")
        XCTAssertEqual(pen.value as? String, "Eraser")

        // A swipe over the mark's last words takes the mark off those words only.
        swipe(from: point(stem, 150), to: point(stem, 250))
        let shorter = NSPredicate(format: "value BEGINSWITH %@ AND value != %@", "Yellow highlight: ", whole)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: shorter, evaluatedWith: stem)], timeout: 5), .completed, "still \(stem.value ?? "")")
        XCTAssertTrue(whole.hasPrefix(try XCTUnwrap(stem.value as? String)), "the words before the swipe keep their mark")
        attachLooks(app, "eraser, part erased")
        // A swipe over the rest cleans the line, and one over clean words marks nothing.
        swipe(from: point(stem, 20), to: point(stem, 160))
        expectNoMarks(stem)
        swipe(from: point(stem, 30), to: point(stem, 230))
        expectNoMarks(stem)

        // The eraser stays in hand on this device. A color puts the pen back.
        app = launch("signed-in", keepPhoneSettings: true)
        openSet(app)
        XCTAssertEqual(app.buttons["practice.pen"].value as? String, "Eraser", "the pen keeps the eraser on this device")
        app.buttons["practice.pen"].tap()
        XCTAssertTrue(app.buttons["practice.pen.eraser"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["practice.pen.eraser"].isSelected)
        XCTAssertFalse(app.buttons["practice.pen.yellow"].isSelected)
        app.buttons["practice.pen.blue"].tap()
        XCTAssertEqual(app.buttons["practice.pen"].value as? String, "Blue")
        swipe(from: point(stem, 30), to: point(stem, 230))
        waitForLabel(stem, valueContaining: "Blue highlight: ")

        // A tap on a mark takes that mark off, with the eraser in hand and with the pen.
        app.buttons["practice.pen"].tap()
        app.buttons["practice.pen.eraser"].tap()
        point(stem, 60).tap()
        expectNoMarks(stem)
        app.buttons["practice.pen"].tap()
        app.buttons["practice.pen.pink"].tap()
        swipe(from: point(stem, 30), to: point(stem, 230))
        waitForLabel(stem, valueContaining: "Pink highlight: ")
        point(stem, 60).tap()
        expectNoMarks(stem)
    }

    /// At the largest text size the question runs well past the screen, on iPad too once it is
    /// turned on its side, so a swipe that scrolls moves the stem.
    @MainActor
    func testASwipeUpOrDownAndASwipeBesideTheWordsScroll() throws {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = launch("signed-in", largestText: true)
        openSet(app)
        let stem = app.staticTexts["practice.stem"]
        let top = stem.frame.minY
        let margin = stem.frame.minX / 2

        // Up, starting on the stem's words: the page scrolls and nothing is marked.
        drag(stem, in: app, from: 60, by: CGVector(dx: 4, dy: -140))
        expectMoved(stem, from: top, by: -100)
        expectNoMarks(stem)
        // Down again, starting on words: back to the top.
        scrollBack(stem, in: app, to: top, from: 60)
        expectNoMarks(stem)

        // Beside the words, in the page's margin: up and down scroll.
        drag(stem, in: app, from: -margin, by: CGVector(dx: 0, dy: -140))
        expectMoved(stem, from: top, by: -100)
        scrollBack(stem, in: app, to: top, from: -margin)
        // Sideways from the margin across the words, and in the gap between two blocks of text,
        // marks nothing: the swipe did not start on words.
        swipe(from: point(stem, -margin, line: 40), to: point(stem, 240, line: 40))
        swipe(from: point(stem, 30, line: -9), to: point(stem, 240, line: -9))
        expectAt(stem, top)
        expectNoMarks(stem)
        attach(app, "swipe, largest text, nothing marked")

        // Along the words the swipe still marks, and the page stays where it is.
        swipe(from: point(stem, 30, line: 40), to: point(stem, 240, line: 40))
        waitForLabel(stem, valueContaining: "Yellow highlight: ")
        expectAt(stem, top)
        attach(app, "swipe, largest text, marked")
    }

    /// A table wider than the screen scrolls sideways in its own box. A sideways swipe that starts
    /// on a cell's words marks them; one that starts in the room around the words, in a cell's
    /// padding or in the room a shorter reading leaves in its column, still scrolls the table.
    /// On iPad the invented table fits the reading column at every text size, so this runs on iPhone.
    @MainActor
    func testAWideTableStillScrollsSidewaysFromBesideItsWords() throws {
        try skipOnIPad()
        let app = launch("signed-in", largestText: true)
        openSet(app)
        // The shortest choice: at this text size the longest is taller than the screen.
        tapVisible(app.buttons["practice.option.3"], in: app)
        waitForSelected(app.buttons["practice.option.3"])
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 10))
        app.buttons["practice.next"].tap()
        waitForLabel(app.staticTexts["practice.count"], containing: "2 of 8")

        let reading = app.staticTexts["1315"]
        reveal(reading, in: app)
        waitUntilStill(reading)
        XCTAssertGreaterThan(app.staticTexts["HR"].frame.maxX, app.windows.firstMatch.frame.maxX, "the table runs past the screen")
        let left = reading.frame.minX
        let top = reading.frame.minY

        // In the padding over a cell's words, sideways: the table scrolls, and comes back from the
        // padding of a cell further along the row, which is on screen by then.
        let later = app.staticTexts["20/min"]
        swipe(from: point(reading, 150, line: -5), to: point(reading, 10, line: -5))
        waitUntilStill(later)
        XCTAssertLessThan(reading.frame.minX, left - 60, "the table did not scroll sideways")
        XCTAssertEqual(reading.frame.minY, top, accuracy: 1, "only the table moved")
        swipe(from: point(later, 10, line: -5), to: point(later, 250, line: -5))
        waitUntilStill(later)
        XCTAssertEqual(reading.frame.minX, left, accuracy: 1)

        // In the room a shorter reading leaves in its column, beside its words.
        let short = app.staticTexts["96%"]
        let room = short.frame.width + 12
        swipe(from: point(short, room, line: short.frame.height / 2), to: point(short, room - 140, line: short.frame.height / 2))
        waitUntilStill(later)
        XCTAssertLessThan(reading.frame.minX, left - 60, "the table did not scroll sideways")
        swipe(from: point(later, 10, line: -5), to: point(later, 250, line: -5))
        waitUntilStill(later)
        XCTAssertEqual(reading.frame.minX, left, accuracy: 1)
        expectNoMarks(reading)
        expectNoMarks(short)

        // On a cell's words, sideways: the words are marked and the table stays.
        swipe(from: point(reading, reading.frame.width - 8, line: reading.frame.height / 2), to: point(reading, 6, line: reading.frame.height / 2))
        waitForLabel(reading, valueContaining: "Yellow highlight: 1315")
        XCTAssertEqual(reading.frame.minX, left, accuracy: 1, "marking does not scroll the table")
        attach(app, "swipe, wide table, cell marked")
    }

    /// A timed exam's question takes the same swipe.
    @MainActor
    func testASwipeMarksAnExamQuestion() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        open(app.buttons["course.tile.exam"], titled: "Exam", in: app)
        let week1 = app.buttons["exam.folder.Week 1"]
        XCTAssertTrue(week1.appears(timeout: 5))
        tapVisible(week1, in: app)
        tapVisible(app.buttons["exam.start"], in: app)
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10))

        let stem = app.staticTexts["practice.stem"]
        XCTAssertTrue(stem.appears(timeout: 5))
        swipe(from: point(stem, 30), to: point(stem, 230))
        waitForLabel(stem, valueContaining: "Yellow highlight: ")
        app.buttons["practice.pen"].tap()
        XCTAssertTrue(app.buttons["practice.pen.eraser"].appears(timeout: 5))
        app.buttons["practice.pen.eraser"].tap()
        swipe(from: point(stem, 20), to: point(stem, 250))
        expectNoMarks(stem)
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
        XCTAssertTrue(app.staticTexts["practice.stem"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["practice.pen"].appears(timeout: 5))
    }

    /// A point so far in from the text's leading edge and down from its top: on its first line
    /// unless told otherwise.
    @MainActor
    private func point(_ element: XCUIElement, _ x: CGFloat, line y: CGFloat = 14) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// A finger's swipe with no hold: down, straight across, and up.
    @MainActor
    private func swipe(from start: XCUICoordinate, to end: XCUICoordinate) {
        start.press(forDuration: 0.02, thenDragTo: end, withVelocity: 500, thenHoldForDuration: 0.1)
    }

    /// A swipe up or down that starts so far in from the text's leading edge, on a line of it that
    /// is on screen now, clear of the bars. It rests before lifting, so the page does not glide on.
    @MainActor
    private func drag(_ element: XCUIElement, in app: XCUIApplication, from x: CGFloat, by travel: CGVector) {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        let line = min(max(window.midY, frame.minY + 30), frame.maxY - 30) - frame.minY
        let start = point(element, x, line: line)
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(travel), withVelocity: 300, thenHoldForDuration: 0.4)
    }

    /// Swipes down from so far in from the text's leading edge until the element is back at `top`.
    /// The first swipe has to move the page.
    @MainActor
    private func scrollBack(_ element: XCUIElement, in app: XCUIApplication, to top: CGFloat, from x: CGFloat) {
        let before = element.frame.minY
        drag(element, in: app, from: x, by: CGVector(dx: -4, dy: 200))
        waitUntilStill(element)
        XCTAssertGreaterThan(element.frame.minY, before + 50, "the page did not scroll back")
        for _ in 0..<5 where element.frame.minY < top - 1 {
            drag(element, in: app, from: x, by: CGVector(dx: -4, dy: 200))
            waitUntilStill(element)
        }
        expectAt(element, top)
    }

    @MainActor
    private func expectNoMarks(_ element: XCUIElement) {
        let clean = NSPredicate(format: "NOT (value CONTAINS %@)", "highlight")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: clean, evaluatedWith: element)], timeout: 5), .completed, "still marked: \(element.value ?? "")")
    }

    /// Waits until the page has come to rest with the element at least so far from where it was.
    @MainActor
    private func expectMoved(_ element: XCUIElement, from top: CGFloat, by distance: CGFloat) {
        waitUntilStill(element)
        XCTAssertLessThan(element.frame.minY, top + distance, "the page did not scroll")
    }

    /// Waits until the page has come to rest with the element back where it was.
    @MainActor
    private func expectAt(_ element: XCUIElement, _ top: CGFloat) {
        waitUntilStill(element)
        XCTAssertEqual(element.frame.minY, top, accuracy: 1, "the page moved")
    }
}
