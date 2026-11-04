import XCTest

/// Deleting a course or study topic from Home: touch and hold its card, Delete asks once in the
/// server's words, the card leaves Home, Undo on the bar or Home's Recently deleted brings it back,
/// and the refusals say why in the server's words. End to end against the in-process fake server of
/// the Debug launch seam, with invented questions and accounts only.
final class CourseDeletionUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    /// Delete asks once, the course leaves Home, and Recently deleted, last on Home, brings it back.
    @MainActor
    func testDeletingACourseFromHomeAndBringingItBackFromRecentlyDeleted() throws {
        let app = home("signed-in")
        XCTAssertFalse(app.buttons["home.recentlyDeleted"].exists, "nothing deleted yet")
        let card = app.buttons["home.course.NURS 220"]
        hold(card, in: app)
        let delete = menuItem(app, "home.hold.delete", "Delete")
        attachLooks(app, "home, holding a course")
        chooseFromMenu(delete)

        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["deleteSheet.message"].appears(timeout: 5))
        XCTAssertEqual(title.label, "Delete NURS 220 and its 146 questions?")
        XCTAssertEqual(app.staticTexts["deleteSheet.message"].label, "You can bring it back for 30 days.")
        XCTAssertTrue(app.buttons["deleteSheet.confirm"].isEnabled)
        attachLooks(app, "course delete, asked once")

        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(card.disappears(timeout: 5), "off Home")
        XCTAssertEqual(app.staticTexts["undo.line"].label, "NURS 220 deleted.")
        XCTAssertTrue(app.buttons["home.course.NURS 310"].exists)
        let recentlyDeleted = app.buttons["home.recentlyDeleted"]
        reveal(recentlyDeleted, in: app)
        XCTAssertTrue(app.staticTexts["1 item · Bring back for 30 days"].exists)
        attachLooks(app, "home, course deleted, Recently deleted last")
        XCTAssertTrue(app.otherElements["undo.bar"].disappears(timeout: 10), "the bar goes by itself")

        open(recentlyDeleted, titled: "Recently deleted", in: app)
        let bringBack = app.buttons["deleted.bringBack.NURS 220"]
        XCTAssertTrue(bringBack.appears(timeout: 5))
        XCTAssertTrue(bringBack.isEnabled)
        XCTAssertTrue(app.staticTexts["From Semester 1"].exists)
        XCTAssertTrue(app.staticTexts["146 questions"].exists)
        XCTAssertTrue(app.staticTexts["COURSES"].exists || app.staticTexts["Courses"].exists)
        attachLooks(app, "recently deleted courses")

        bringBack.tap()
        XCTAssertTrue(app.staticTexts["NURS 220 is back."].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["No course or study topic was deleted in the last 30 days."].appears(timeout: 5))
        attach(app, "recently deleted courses, brought back")
        goBack(app, from: "Recently deleted")
        XCTAssertTrue(card.appears(timeout: 5), "back on Home")
        XCTAssertTrue(recentlyDeleted.disappears(timeout: 5), "nothing left to bring back")
    }

    /// A topic deletes the same way, called by its name, and Undo on the bar brings it right back.
    @MainActor
    func testDeletingATopicAndUndoOnTheBar() throws {
        let app = home("signed-in")
        let name = "Invented Pharmacology"
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let field = app.textFields["newTopic.name"]
        XCTAssertTrue(field.appears(timeout: 5))
        field.typeText(name)
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars[name].appears(timeout: 10))
        goBack(app, from: name)

        let card = app.buttons["home.topic.\(name)"]
        hold(card, in: app)
        chooseFromMenu(menuItem(app, "home.hold.delete", "Delete"))
        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        waitForLabel(title, containing: "Delete \(name)?")
        XCTAssertEqual(app.staticTexts["deleteSheet.message"].label, "You can bring it back for 30 days.")
        attach(app, "topic delete, asked once")
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(card.disappears(timeout: 5))
        XCTAssertTrue(app.otherElements["home.noTopics"].appears(timeout: 5) || app.staticTexts["A topic is a place for questions that are not a course: a certification, a language, your own notes."].exists)
        let line = app.staticTexts["undo.line"]
        XCTAssertEqual(line.label, "\(name) deleted.")

        app.buttons["undo.button"].tap()
        waitForLabel(line, containing: "\(name) is back.")
        XCTAssertTrue(card.appears(timeout: 5), "back under Study topics")
        attach(app, "topic back")
    }

    /// An exam still going in the course: the question says why in the server's words, and Delete waits.
    @MainActor
    func testACourseWithAnExamGoingCannotBeDeletedYet() throws {
        let app = home("exam-in-progress")
        let card = app.buttons["home.course.NURS 310"]
        hold(card, in: app)
        chooseFromMenu(menuItem(app, "home.hold.delete", "Delete"))
        let problem = app.staticTexts["An exam in NURS 310 is still going. Finish or leave that exam first."]
        XCTAssertTrue(problem.appears(timeout: 5))
        XCTAssertFalse(app.buttons["deleteSheet.confirm"].isEnabled, "Delete waits")
        attachLooks(app, "course delete refused for now")
        tapWhenStill(app.buttons["deleteSheet.cancel"])
        XCTAssertTrue(app.navigationBars["Home"].appears(timeout: 5))
        XCTAssertTrue(card.exists, "nothing was deleted")
        XCTAssertFalse(app.otherElements["undo.bar"].exists)
    }

    /// A new course took the code since: Recently deleted says so in the server's words, and Bring
    /// back is off until one of them is renamed.
    @MainActor
    func testACodeTakenSinceKeepsBringBackOff() throws {
        let app = home("signed-in")
        hold(app.buttons["home.course.NURS 220"], in: app)
        chooseFromMenu(menuItem(app, "home.hold.delete", "Delete"))
        XCTAssertTrue(app.staticTexts["deleteSheet.message"].appears(timeout: 5))
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(app.buttons["home.course.NURS 220"].disappears(timeout: 5))

        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.course.1", "New course in Semester 1"))
        let code = app.textFields["newCourse.code"]
        XCTAssertTrue(code.appears(timeout: 5))
        code.typeText("NURS 220")
        app.textFields["newCourse.title"].tap()
        app.textFields["newCourse.title"].typeText("Invented Fundamentals")
        app.buttons["newCourse.save"].tap()
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 10), "the code is free while it is deleted")
        goBack(app, from: "NURS 220")

        let recentlyDeleted = app.buttons["home.recentlyDeleted"]
        reveal(recentlyDeleted, in: app)
        open(recentlyDeleted, titled: "Recently deleted", in: app)
        let refusal = app.staticTexts["Semester 1 already has a course with the code NURS 220. Rename one of them, then bring this one back."]
        XCTAssertTrue(refusal.appears(timeout: 5))
        XCTAssertFalse(app.buttons["deleted.bringBack.NURS 220"].isEnabled, "Bring back waits")
        attachLooks(app, "recently deleted, code taken")
    }

    /// The app on Home, back from the course it opens on arrival.
    @MainActor
    private func home(_ scenario: String) -> XCUIApplication {
        let app = launch(scenario)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        goBack(app, from: "NURS 310")
        XCTAssertTrue(app.navigationBars["Home"].appears(timeout: 5))
        return app
    }

    /// Touches and holds a card on Home until its menu shows Delete.
    @MainActor
    private func hold(_ card: XCUIElement, in app: XCUIApplication) {
        reveal(card, in: app)
        card.press(forDuration: 1.2)
        XCTAssertTrue(menuItem(app, "home.hold.delete", "Delete").appears(timeout: 5))
    }
}
