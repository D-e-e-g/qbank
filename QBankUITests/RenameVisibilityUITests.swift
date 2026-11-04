import XCTest

/// Rename from the screen that is already open, against the fake student of the Debug launch seam.
/// Edit page is in More, beside + on a page's screen, and opens the page editor. Rename is in More,
/// beside + on a topic's or a course's screen, and opens the same sheet Home opens from holding
/// the card. Only the name changes: folders, pages, sets and past exams stay.
final class RenameVisibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEditPageRenamesThePageFromThePageScreen() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)

        let more = app.buttons["page.more"]
        XCTAssertTrue(more.appears(timeout: 5))
        XCTAssertEqual(more.label, "More for Exam 1")
        XCTAssertFalse(app.buttons["Edit page"].isHittable, "Edit page is not a row on the screen")
        XCTAssertEqual(app.staticTexts["page.note"].label, "2 folders · 3 practice sets · 43 questions")
        // Study material's Edit still orders folders. Name and folders stays hidden until then.
        XCTAssertEqual(app.buttons["page.edit"].label, "Edit study material")
        XCTAssertFalse(app.buttons["page.editPage"].exists)
        attachLooks(app, "after page")

        app.buttons["page.edit"].tap()
        let buried = app.buttons["page.editPage"]
        XCTAssertTrue(buried.appears(timeout: 5))
        XCTAssertEqual(buried.label, "Name and folders of Exam 1")
        app.buttons["page.edit"].tap()
        XCTAssertTrue(buried.disappears(timeout: 5))

        tapWhenStill(more)
        let editPage = menuItem(app, "page.more.editPage", "Edit page")
        XCTAssertTrue(editPage.appears(timeout: 5))
        attachLooks(app, "after page, More")
        chooseFromMenu(editPage)
        XCTAssertTrue(app.navigationBars["Edit Exam 1"].appears(timeout: 5))
        let name = app.textFields["editPage.name"]
        XCTAssertEqual(name.value as? String, "Exam 1")
        let caption = app.staticTexts["editPage.name.caption"]
        XCTAssertTrue(caption.exists, "Page name stays visible while the box holds a name")
        XCTAssertEqual(caption.label, "Page name")
        XCTAssertTrue(app.buttons["editPage.chip.free.Week 1"].exists)
        XCTAssertTrue(app.buttons["editPage.chip.free.Week 2"].exists)
        name.clearAndType("First exam")
        attachLooks(app, "after page editor")
        app.buttons["editPage.save"].tap()

        XCTAssertTrue(app.navigationBars["First exam"].appears(timeout: 10))
        XCTAssertEqual(app.staticTexts["page.note"].label, "2 folders · 3 practice sets · 43 questions")
        XCTAssertTrue(app.buttons["folder.Week 1"].exists)
        XCTAssertTrue(app.buttons["folder.Week 2"].exists)
        XCTAssertTrue(app.buttons["page.sitting.e0000000-0000-4000-8000-000000000001"].exists)
        XCTAssertEqual(app.buttons["page.more"].label, "More for First exam")
        attachLooks(app, "after page renamed")

        goBack(app, from: "First exam")
        let renamed = app.buttons["course.page.First exam"]
        XCTAssertTrue(renamed.appears(timeout: 5))
        waitForLabel(renamed, containing: "First exam, Exam, 2 folders · 43 questions, 26 of 43")
        waitForLabel(app.buttons["course.page.Exam 2"], containing: "Exam 2, Exam, 1 folder · 31 questions")
        XCTAssertTrue(app.buttons["folder.Weeks 1-3"].exists)
    }

    @MainActor
    func testRenameRenamesATopicFromTheTopicScreen() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        goBack(app, from: "NURS 310")

        let topic = "Invented Pharmacology"
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let created = app.textFields["newTopic.name"]
        XCTAssertTrue(created.appears(timeout: 5))
        created.typeText(topic)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))

        let more = app.buttons["course.more"]
        XCTAssertTrue(more.appears(timeout: 5))
        XCTAssertEqual(more.label, "More for \(topic)")
        XCTAssertFalse(app.buttons["Rename"].isHittable, "Rename is not a row on the screen")
        XCTAssertTrue(app.staticTexts["This topic has no question sets yet."].exists)
        attachLooks(app, "after topic")

        more.tap()
        let rename = menuItem(app, "course.rename", "Rename")
        XCTAssertTrue(rename.appears(timeout: 5))
        chooseFromMenu(rename)
        XCTAssertTrue(app.navigationBars["Rename topic"].appears(timeout: 5))
        let name = app.textFields["renameCourse.title"]
        XCTAssertEqual(name.value as? String, topic)
        name.clearAndType("Invented Drug Names")
        attachLooks(app, "after rename topic")
        app.buttons["renameCourse.save"].tap()

        XCTAssertTrue(app.navigationBars["Invented Drug Names"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["This topic has no question sets yet."].exists)
        waitForLabel(app.staticTexts["course.summary"], containing: "0 questions · 0 folders")
        attachLooks(app, "after topic renamed")

        goBack(app, from: "Invented Drug Names")
        XCTAssertTrue(app.buttons["home.topic.Invented Drug Names"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["home.topic.\(topic)"].exists)
    }

    @MainActor
    func testRenameRenamesACourseFromTheCourseScreen() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let summary = app.staticTexts["course.summary"]
        XCTAssertTrue(summary.appears(timeout: 5))
        waitForLabel(summary, containing: "Mental Health · 86 questions · 4 folders")

        let more = app.buttons["course.more"]
        XCTAssertTrue(more.appears(timeout: 5))
        XCTAssertEqual(more.label, "More for NURS 310")
        XCTAssertFalse(app.buttons["Rename"].isHittable, "Rename is not a row on the screen")
        attachLooks(app, "after course")

        more.tap()
        let rename = menuItem(app, "course.rename", "Rename")
        XCTAssertTrue(rename.appears(timeout: 5))
        attachLooks(app, "after course, More")
        chooseFromMenu(rename)
        XCTAssertTrue(app.navigationBars["Rename course"].appears(timeout: 5))
        XCTAssertEqual(app.textFields["renameCourse.code"].value as? String, "NURS 310")
        let title = app.textFields["renameCourse.title"]
        XCTAssertEqual(title.value as? String, "Mental Health")
        title.clearAndType("Psychiatric Nursing")
        attachLooks(app, "after rename course")
        app.buttons["renameCourse.save"].tap()

        XCTAssertTrue(app.navigationBars["Rename course"].disappears(timeout: 10))
        XCTAssertTrue(app.navigationBars["NURS 310"].exists, "the code is the title, and it was not changed")
        waitForLabel(summary, containing: "Psychiatric Nursing · 86 questions · 4 folders")
        waitForLabel(summary, containing: "35 of 86 answered · 24 fully right · 61 of 92 points")
        waitForLabel(app.buttons["course.page.Exam 1"], containing: "Exam 1, Exam, 2 folders · 43 questions, 26 of 43")
        waitForLabel(app.buttons["course.page.Exam 2"], containing: "Exam 2, Exam, 1 folder · 31 questions")
        XCTAssertTrue(app.buttons["folder.Weeks 1-3"].exists)
        attachLooks(app, "after course renamed")

        goBack(app, from: "NURS 310")
        let card = app.buttons["home.course.NURS 310"]
        XCTAssertTrue(card.appears(timeout: 5))
        waitForLabel(card, containing: "Psychiatric Nursing")
    }
}

private extension XCUIElement {
    /// Puts the cursor at the end of the field, then replaces what it holds.
    func clearAndType(_ text: String) {
        tap()
        let current = value as? String ?? ""
        coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        typeText(text)
    }
}
