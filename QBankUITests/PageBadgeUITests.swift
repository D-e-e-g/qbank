import XCTest

/// Pages and their badges end to end against the in-process fake server of the Debug launch seam:
/// a course and a topic list Pages, each page with its badge as a tag beside its name, New page
/// asks nothing more and makes Page N with no badge, and a page's editor sets and clears its badge.
/// Invented courses and topics only.
final class PageBadgeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testACoursePagesBadgeIsSetAndClearedInItsEditor() throws {
        try skipOnIPad()
        let app = launch("signed-in")

        // Her course lists Pages; her pages from before badges keep their names and say Exam.
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pages"].appears(timeout: 5))
        let exam1 = app.buttons["course.page.Exam 1"]
        let exam2 = app.buttons["course.page.Exam 2"]
        waitForLabel(exam1, containing: "Exam 1, Exam, ")
        waitForLabel(exam2, containing: "Exam 2, Exam, ")
        attachLooks(app, "B-1 course, pages with badges")

        // Its editor: Badge, with Exam picked and its one hint line.
        openEditor(app, "Exam 1")
        let badge = app.otherElements["editPage.badge"]
        reveal(badge, in: app)
        XCTAssertEqual(badge.buttons.allElementsBoundByIndex.map(\.label), ["Exam", "Concept", "Study", "None"])
        XCTAssertTrue(badge.buttons["Exam"].isSelected)
        XCTAssertTrue(app.staticTexts["Says what the page is for"].exists)
        attachLooks(app, "B-2 page editor, Badge")

        // Concept: the tag says so.
        badge.buttons["Concept"].tap()
        XCTAssertTrue(badge.buttons["Concept"].isSelected)
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.otherElements["editPage"].disappears(timeout: 10))
        goBack(app, from: "Exam 1")
        waitForLabel(exam1, containing: "Exam 1, Concept, ")

        // None: no tag.
        openEditor(app, "Exam 2")
        tapVisible(badge.buttons["None"], in: app)
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.otherElements["editPage"].disappears(timeout: 10))
        goBack(app, from: "Exam 2")
        waitForLabel(exam2, containing: "Exam 2, 1 folder")

        // New page asks nothing about a badge, makes Page 3, and lists it with no tag.
        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
        XCTAssertEqual(app.textFields["editPage.name"].value as? String, "Page 3")
        XCTAssertFalse(app.otherElements["editPage.badge"].exists, "a new page has no badge")
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Page 3"].appears(timeout: 10))
        goBack(app, from: "Page 3")
        waitForLabel(app.buttons["course.page.Page 3"], containing: "Page 3, No folders yet")
        attachLooks(app, "B-3 course, a badge changed, one cleared, a new page")
    }

    @MainActor
    func testATopicsPagesHaveNoBadgeUntilOneIsSet() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        goBack(app, from: "NURS 310")

        // A topic, with two pages from its +.
        let topic = "Invented Systems Design"
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let field = app.textFields["newTopic.name"]
        XCTAssertTrue(field.appears(timeout: 5))
        field.typeText(topic)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))
        for page in ["Page 1", "Page 2"] {
            app.buttons["course.add"].tap()
            chooseFromMenu(menuItem(app, "course.add.page", "New page"))
            XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
            XCTAssertEqual(app.textFields["editPage.name"].value as? String, page)
            app.buttons["editPage.save"].tap()
            XCTAssertTrue(app.navigationBars[page].appears(timeout: 10))
            goBack(app, from: page)
        }
        XCTAssertTrue(app.staticTexts["Pages"].appears(timeout: 5))
        waitForLabel(app.buttons["course.page.Page 1"], containing: "Page 1, No folders yet")

        // Study on Page 1: its tag shows; Page 2 has none.
        openEditor(app, "Page 1")
        let badge = app.otherElements["editPage.badge"]
        reveal(badge, in: app)
        XCTAssertTrue(badge.buttons["None"].isSelected)
        badge.buttons["Study"].tap()
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.otherElements["editPage"].disappears(timeout: 10))
        goBack(app, from: "Page 1")
        waitForLabel(app.buttons["course.page.Page 1"], containing: "Page 1, Study, ")
        waitForLabel(app.buttons["course.page.Page 2"], containing: "Page 2, No folders yet")
        attachLooks(app, "B-4 topic, pages with and without a badge")
    }

    /// Opens a page from the course page, then Edit and Name and folders: its editor.
    @MainActor
    private func openEditor(_ app: XCUIApplication, _ page: String) {
        open(app.buttons["course.page.\(page)"], titled: page, in: app)
        app.buttons["page.edit"].tap()
        tapWhenStill(app.buttons["page.editPage"])
        XCTAssertTrue(app.navigationBars["Edit \(page)"].appears(timeout: 5))
    }
}
