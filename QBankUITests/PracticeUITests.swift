import XCTest

/// Slice 1b end to end: practicing a set in every question format against the in-process fake
/// server of the Debug launch seam, which scores answers with the server's rules. Invented
/// questions and accounts only.
final class PracticeUITests: XCTestCase {
    private static let set = "Mixed Clinical Judgment"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testEveryFormatThenTheResult() throws {
        let app = launch("signed-in")
        openSet(app)

        // 1 Single answer: the right choice.
        expectQuestion(app, count: "1 of 8", format: "Single answer")
        attach(app, "1b-1 single, open")
        tapVisible(app.buttons["practice.option.0"], in: app)
        XCTAssertTrue(app.buttons["practice.option.0"].isSelected)
        attach(app, "1b-1 single, picked")
        check(app)
        XCTAssertTrue(feedback(app).label.hasPrefix("Correct"), feedback(app).label)
        attach(app, "1b-4 single, correct")
        reveal(app.staticTexts["practice.rationale"], in: app)
        attach(app, "1b-4 single, rationale")
        let image = app.buttons["practice.image"]
        tapVisible(image, in: app)
        XCTAssertTrue(app.buttons["imageViewer.close"].appears(timeout: 5))
        attach(app, "1b-2 image full screen")
        app.buttons["imageViewer.close"].tap()
        XCTAssertTrue(app.buttons["imageViewer.close"].disappears(timeout: 5))
        attach(app, "1b-4 single, rationale image")
        next(app)

        // 2 Priority with a table: a wrong choice.
        expectQuestion(app, count: "2 of 8", format: "Priority / first action")
        XCTAssertTrue(app.descendants(matching: .any)["practice.table"].exists)
        tapVisible(app.buttons["practice.option.1"], in: app)
        attach(app, "1b-2 priority, picked")
        check(app)
        XCTAssertTrue(feedback(app).label.hasPrefix("Not correct"), feedback(app).label)
        attach(app, "1b-4 priority, not correct")
        next(app)

        // 3 Select all that apply: two right and one wrong is 1 of 3 points, flagged as a guess.
        expectQuestion(app, count: "3 of 8", format: "Select all that apply")
        let checkButton = app.buttons["practice.check"]
        XCTAssertFalse(checkButton.isEnabled, "nothing picked yet")
        for option in [0, 1, 3] {
            tapVisible(app.buttons["practice.option.\(option)"], in: app)
        }
        tapVisible(app.switches["practice.guess"], in: app)
        attach(app, "1b-3 select all, picked")
        check(app)
        let partly = feedback(app).label
        XCTAssertTrue(partly.contains("Partly correct"), partly)
        XCTAssertTrue(partly.contains("1 of 3 points"), partly)
        XCTAssertTrue(partly.contains("+1 for each correct choice, -1 for each wrong one"), partly)
        XCTAssertTrue(partly.contains("Flagged as a guess"), partly)
        attach(app, "1b-4 select all, partly correct")
        app.swipeUp()
        attach(app, "1b-4 select all, reasons")
        app.swipeUp()
        attach(app, "1b-4 select all, rationale and terms")
        next(app)

        // 4 Highlight: two of the three objective entries.
        expectQuestion(app, count: "4 of 8", format: "Highlight")
        tapVisible(app.buttons["practice.segment.0"], in: app)
        tapVisible(app.buttons["practice.segment.2"], in: app)
        attach(app, "1b-5 highlight, picked")
        check(app)
        XCTAssertTrue(feedback(app).label.contains("2 of 3 points"), feedback(app).label)
        attach(app, "1b-5 highlight, checked")
        app.swipeUp()
        attach(app, "1b-5 highlight, notes")
        next(app)

        // 5 Ordering: put every item in place with the move buttons.
        expectQuestion(app, count: "5 of 8", format: "Ordering")
        attach(app, "1b-6 ordering, open")
        sortOrder(app, count: 4)
        attach(app, "1b-6 ordering, sorted")
        check(app)
        XCTAssertTrue(feedback(app).label.hasPrefix("Correct"), feedback(app).label)
        XCTAssertTrue(feedback(app).label.contains("4 of 4 points"), feedback(app).label)
        attach(app, "1b-6 ordering, correct")
        next(app)

        // 6 Matching: Check answer waits until every row has a match.
        expectQuestion(app, count: "6 of 8", format: "Matching")
        XCTAssertFalse(app.buttons["practice.check"].isEnabled)
        choose(app, menu: "practice.match.0", option: "Fidelity")
        tapVisible(app.buttons["practice.match.1"], in: app)
        XCTAssertTrue(app.buttons["Veracity"].appears(timeout: 5))
        attach(app, "1b-7 matching, menu open")
        chooseFromMenu(app.buttons["Veracity"])
        choose(app, menu: "practice.match.2", option: "Justice")
        XCTAssertFalse(app.buttons["practice.check"].isEnabled, "one row is still empty")
        choose(app, menu: "practice.match.3", option: "Nonmaleficence")
        attach(app, "1b-7 matching, filled")
        check(app)
        XCTAssertTrue(feedback(app).label.contains("3 of 4 points"), feedback(app).label)
        attach(app, "1b-7 matching, checked")
        app.swipeUp()
        attach(app, "1b-7 matching, correct match shown")
        next(app)

        // 7 Matrix: one pill per row.
        expectQuestion(app, count: "7 of 8", format: "Matrix")
        tapVisible(app.buttons["practice.matrix.0.Orientation"], in: app)
        tapVisible(app.buttons["practice.matrix.1.Working"], in: app)
        tapVisible(app.buttons["practice.matrix.2.Working"], in: app)
        attach(app, "1b-8 matrix, picked")
        check(app)
        XCTAssertTrue(feedback(app).label.contains("2 of 3 points"), feedback(app).label)
        attach(app, "1b-8 matrix, checked")
        next(app)

        // 8 Drop-down: a menu in each blank, then See results.
        expectQuestion(app, count: "8 of 8", format: "Drop-down")
        choose(app, menu: "practice.blank.0", option: "mechanical restraint")
        attach(app, "1b-9 drop-down, one filled")
        choose(app, menu: "practice.blank.1", option: "seclusion")
        choose(app, menu: "practice.blank.2", option: "chemical restraint")
        attach(app, "1b-9 drop-down, filled")
        check(app)
        XCTAssertTrue(feedback(app).label.contains("2 of 3 points"), feedback(app).label)
        attach(app, "1b-9 drop-down, checked")
        app.swipeUp()
        attach(app, "1b-9 drop-down, correct answers")
        XCTAssertEqual(app.buttons["practice.next"].label, "See results")
        next(app)

        // The set result: single and ordering fully right, priority missed, the rest partly right.
        let title = app.staticTexts["result.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "2 of 8 fully right")
        XCTAssertTrue(app.staticTexts["result.points"].label.hasPrefix("15 of 22 points · "), app.staticTexts["result.points"].label)
        XCTAssertEqual(app.descendants(matching: .any)["result.stat.Partly right"].label, "5, Partly right")
        XCTAssertEqual(app.descendants(matching: .any)["result.stat.Missed"].label, "1, Missed")
        XCTAssertEqual(app.descendants(matching: .any)["result.stat.Guessed"].label, "1, Guessed")
        attach(app, "1b-10 result")
        let guessed = app.buttons["result.question.3"]
        tapVisible(guessed, in: app)
        XCTAssertTrue(guessed.label.contains("Guessed - Partly correct"), guessed.label)
        attach(app, "1b-10 result, question opened")
        app.swipeUp()
        attach(app, "1b-10 result, end")

        app.buttons["result.back"].tap()
        XCTAssertTrue(app.navigationBars["Weeks 1-3"].appears(timeout: 5))
        let set = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(set.appears(timeout: 5))
        // The folder reads the course again once practice has closed, so the line says how the set
        // stood before until that read lands.
        waitForLabel(set, containing: "Done today · 2 of 8 fully right")
    }

    @MainActor
    func testCloseLeavesTheSetMidway() throws {
        let app = launch("signed-in")
        openSet(app)
        expectQuestion(app, count: "1 of 8", format: "Single answer")
        tapVisible(app.buttons["practice.option.2"], in: app)
        check(app)
        next(app)
        expectQuestion(app, count: "2 of 8", format: "Priority / first action")
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Weeks 1-3"].appears(timeout: 5))
        let set = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(set.appears(timeout: 5))
        waitForLabel(set, containing: "1 of 8 answered")
    }

    // MARK: Helpers

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
    private func expectQuestion(_ app: XCUIApplication, count: String, format: String) {
        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.appears(timeout: 5))
        let changed = NSPredicate(format: "label BEGINSWITH %@", "\(count),")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: counter)], timeout: 5), .completed, "count is \(counter.label)")
        let meta = app.descendants(matching: .any)["practice.meta"]
        XCTAssertTrue(meta.label.hasPrefix(format), meta.label)
    }

    @MainActor
    private func check(_ app: XCUIApplication) {
        let button = app.buttons["practice.check"]
        XCTAssertTrue(button.isEnabled)
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
    }

    @MainActor
    private func feedback(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["practice.feedback"]
    }

    @MainActor
    private func next(_ app: XCUIApplication) {
        app.buttons["practice.next"].tap()
    }

    /// Opens a menu and picks one of its options, again if the menu drops the tap.
    @MainActor
    private func choose(_ app: XCUIApplication, menu: String, option: String) {
        tapVisible(app.buttons[menu], in: app)
        chooseFromMenu(app.buttons[option])
    }

    /// Moves each item to its place with the up buttons, first item first.
    @MainActor
    private func sortOrder(_ app: XCUIApplication, count: Int) {
        for target in 0..<count {
            for _ in 0..<count {
                let rows = (0..<count).map { original in
                    (original, app.descendants(matching: .any)["practice.order.item.\(original)"].frame.minY)
                }
                let position = rows.sorted { $0.1 < $1.1 }.firstIndex { $0.0 == target } ?? target
                guard position > target else { break }
                tapVisible(app.buttons["practice.order.\(target).up"], in: app)
            }
        }
    }
}
