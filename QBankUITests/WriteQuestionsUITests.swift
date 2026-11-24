import XCTest

/// Writing a set by hand: the set editor under Add, what the import check refuses said in the
/// editor's words when a question is not finished, saving through Import, and practicing what was written, on a free account whose
/// bank is on the phone, with no network at all. Invented sets only. A unit test cannot do this
/// job: it is the real editor, typed into with the keyboard, that shows the refusal on
/// screen, a draft coming back after she leaves, and the saved set opening in the same runner an
/// imported one does.
final class WriteQuestionsUITests: XCTestCase {
    private let topic = "Invented Sleep Notes"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWritingAQuestionAndPracticingIt() throws {
        try skipOnIPad()
        let app = launch("free-new-bank", online: false)

        // A new bank is empty: a study topic for the set to go into.
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText(topic)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))

        openTab(app, "Add")
        XCTAssertTrue(app.navigationBars["Add questions"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["add.draft.Invented Sleep Habits"].exists)
        app.buttons["add.write"].tap()
        XCTAssertTrue(app.navigationBars["Write questions"].appears(timeout: 5))
        attachLooks(app, "write, empty editor")

        // A single-answer question with its fourth choice left empty and none marked: the empty
        // choice is left out, and the editor says what the import check refused.
        type("Invented Sleep Habits", into: "write.title", in: app)
        type("Which habit helps sleep?", into: "write.q1.ask", in: app)
        type("A regular bedtime", into: "write.q1.choice.0", in: app)
        type("An evening nap", into: "write.q1.choice.1", in: app)
        type("Coffee at night", into: "write.q1.choice.2", in: app)
        type("A steady schedule sets the body clock.", into: "write.q1.explanation", in: app)
        tapVisible(app.buttons["write.save"], in: app)
        let errors = app.descendants(matching: .any)["write.errors"]
        XCTAssertTrue(errors.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Question 1: mark the right answer"].exists)
        XCTAssertEqual(errors.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Question'")).count, 1, "the empty choice is not a problem")
        let inline = app.staticTexts["write.q1.problem"]
        XCTAssertTrue(inline.exists)
        XCTAssertTrue(inline.label.contains("Mark the right answer"), inline.label)
        attachLooks(app, "write, the check's errors")

        // The fix: mark the right one.
        tapVisible(app.buttons["write.q1.right.0"], in: app)
        XCTAssertTrue(app.buttons["write.q1.right.0"].isSelected)
        XCTAssertTrue(errors.disappears(timeout: 5), "a change needs a new check")
        XCTAssertFalse(inline.exists)

        // A draft stays on the phone when she leaves, and comes back as she left it.
        goBack(app, from: "Write questions")
        let draft = app.buttons["add.draft.Invented Sleep Habits"]
        XCTAssertTrue(draft.appears(timeout: 5))
        XCTAssertTrue(draft.label.contains("1 question"), draft.label)
        attach(app, "write, draft on Add")
        draft.tap()
        XCTAssertTrue(app.navigationBars["Write questions"].appears(timeout: 5))
        XCTAssertEqual(app.textFields["write.title"].value as? String, "Invented Sleep Habits")
        XCTAssertTrue(app.buttons["write.q1.right.0"].isSelected)

        // A true-or-false question: the two choices are fixed.
        tapVisible(app.buttons["write.add"], in: app)
        // Question 2's own kind control: the second "True or false" segment on the screen.
        let kind = app.descendants(matching: .any)["write.q2.kind"].buttons["True or false"]
        tapVisible(kind, in: app)
        type("Naps at 6 PM make it easier to fall asleep.", into: "write.q2.ask", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["write.q2.choice.0"].exists, "True and False are not typed")
        tapVisible(app.buttons["write.q2.right.1"], in: app)
        XCTAssertTrue(app.buttons["write.q2.right.1"].isSelected)
        attachLooks(app, "write, two questions")

        // Saved through Import into the course's Unsorted folder.
        waitForLabel(app.buttons["import.course"], containing: topic)
        tapVisible(app.buttons["write.save"], in: app)
        let title = app.staticTexts["import.done.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Saved")
        XCTAssertEqual(
            app.staticTexts["import.done.copy"].label,
            "“Invented Sleep Habits” · 2 questions in \(topic), Unsorted. It is in the topic’s Folders list until you move it."
        )
        XCTAssertTrue(app.buttons["import.done.another"].label.contains("Write another set"))
        attachLooks(app, "write, saved")

        // The draft is gone, and the set practices like any imported one, with its explanation.
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        let set = app.buttons["course.set.Invented Sleep Habits"]
        XCTAssertTrue(set.appears(timeout: 5))
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 2"))
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        let feedback = app.descendants(matching: .any)["practice.feedback"]
        XCTAssertTrue(feedback.appears(timeout: 5))
        XCTAssertTrue(feedback.label.hasPrefix("Correct"), feedback.label)
        let rationale = app.descendants(matching: .any)["practice.rationale"]
        reveal(rationale, in: app)
        XCTAssertTrue(rationale.label.contains("A steady schedule sets the body clock."), rationale.label)
        attach(app, "write, practiced")
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        openTab(app, "Add")
        XCTAssertFalse(app.descendants(matching: .any)["add.draft.Invented Sleep Habits"].exists, "saving forgets the draft")
    }

    /// A saved set opened in the editor and saved again: the new version keeps the answers given
    /// to the question she left alone, and Restore brings the earlier version back. A unit test
    /// cannot do this job: it is the real bank on the phone that keeps answers across a replace,
    /// and the long press, the sheet, and the Restore button are only on screen.
    @MainActor
    func testEditingASetKeepsItsAnswers() throws {
        try skipOnIPad()
        let app = launch("free-new-bank", online: false)
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText(topic)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))

        // A set of a single-answer question and a select-all one, written by hand.
        openTab(app, "Add")
        app.buttons["add.write"].tap()
        XCTAssertTrue(app.navigationBars["Write questions"].appears(timeout: 5))
        type("Invented Sleep Habits", into: "write.title", in: app)
        type("Which habit helps sleep?", into: "write.q1.ask", in: app)
        type("A regular bedtime", into: "write.q1.choice.0", in: app)
        type("An evening nap", into: "write.q1.choice.1", in: app)
        tapVisible(app.buttons["write.q1.right.0"], in: app)
        tapVisible(app.buttons["write.add"], in: app)
        tapVisible(app.descendants(matching: .any)["write.q2.kind"].buttons["Select all"], in: app)
        type("Which habits help sleep?", into: "write.q2.ask", in: app)
        type("A dark room", into: "write.q2.choice.0", in: app)
        type("A cool room", into: "write.q2.choice.1", in: app)
        type("Coffee at night", into: "write.q2.choice.2", in: app)
        // Select all needs at least one right choice, and says so until one is marked.
        waitForLabel(app.buttons["import.course"], containing: topic)
        tapVisible(app.buttons["write.save"], in: app)
        XCTAssertTrue(app.staticTexts["Question 2: mark at least one right answer"].appears(timeout: 5))
        tapVisible(app.buttons["write.q2.right.0"], in: app)
        tapVisible(app.buttons["write.q2.right.1"], in: app)
        XCTAssertTrue(app.buttons["write.q2.right.0"].isSelected)
        XCTAssertTrue(app.buttons["write.q2.right.1"].isSelected)
        attachLooks(app, "write, select all")
        tapVisible(app.buttons["write.save"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.title"].appears(timeout: 5))
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))

        // She answers the first question and leaves.
        let set = app.buttons["course.set.Invented Sleep Habits"]
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        waitForLabel(set, containing: "1 of 2 answered")
        XCTAssertFalse(app.buttons["course.restore"].exists, "one version, nothing to restore")

        // She opens the set to edit and changes the second question.
        set.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "edit.Invented Sleep Habits", "Edit questions"))
        XCTAssertTrue(app.navigationBars["Edit questions"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["write.title"].label, "Invented Sleep Habits", "a saved set keeps its name")
        XCTAssertTrue(app.buttons["write.q1.right.0"].isSelected)
        XCTAssertTrue(app.buttons["write.q2.right.1"].isSelected)
        XCTAssertFalse(app.buttons["write.q2.right.2"].isSelected)
        attachLooks(app, "edit, a saved set")
        type(" tonight", into: "write.q2.ask", in: app)
        tapVisible(app.buttons["write.q2.right.2"], in: app)
        XCTAssertEqual(app.buttons["write.save"].label, "Save new version")
        tapVisible(app.buttons["write.save"], in: app)
        XCTAssertEqual(app.staticTexts["import.done.title"].label, "Replaced")
        XCTAssertTrue(app.staticTexts["import.done.copy"].label.contains("The previous version can be restored from its folder."))
        attachLooks(app, "edit, saved as a new version")
        app.buttons["import.done.open"].tap()

        // The new version has the answer to the question she left alone, and Restore is offered.
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        XCTAssertTrue(set.appears(timeout: 5))
        waitForLabel(set, containing: "1 of 2 answered")
        let restore = app.buttons["course.restore"]
        XCTAssertTrue(restore.appears(timeout: 5))
        attach(app, "edit, back in the folder")

        // Restore brings the earlier version back, with its answer still on it.
        restore.tap()
        app.sheets.buttons["Restore"].firstMatch.tap()
        XCTAssertTrue(app.buttons["course.restore"].appears(timeout: 5))
        waitForLabel(set, containing: "1 of 2 answered")
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("2 of 2"), "picks up at the second question")
        app.buttons["practice.close"].tap()
    }

    /// Types into one of the editor's fields: scrolls it into view, taps it, and types.
    @MainActor
    private func type(_ text: String, into id: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any)[id]
        reveal(field, in: app)
        focus(field, in: app)
        field.typeText(text)
    }
}
