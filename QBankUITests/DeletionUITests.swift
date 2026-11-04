import XCTest

/// Deleting a folder with its sets, a set, and a past exam, each after a warning in the server's
/// words; Undo from the bar; Recently deleted; and a delete refused for now. End to end against the
/// in-process fake server of the Debug launch seam, with invented questions and accounts only.
final class DeletionUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    /// Deleting a folder warns that its sets go too, naming each one, and Undo brings it all back.
    @MainActor
    func testDeletingAFolderNamesItsSetsAndUndoBringsItBack() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        attach(app, "folder with Delete")

        app.buttons["folder.delete"].tap()
        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Delete Week 2?")
        let message = app.staticTexts["deleteSheet.message"]
        XCTAssertTrue(message.appears(timeout: 5))
        XCTAssertEqual(
            message.label,
            "Its 2 sets go with it: Psychosocial Assessment and Safety Screening and Therapeutic Communication and the Relationship, 26 questions in all. You have answered 9 of them: those answers stop counting toward your progress, and 5 questions leave your Review list. It comes off Exam 1. Your 2 past exams over it stay. You can undo this for 30 days."
        )
        XCTAssertTrue(app.buttons["deleteSheet.confirm"].isEnabled)
        attachLooks(app, "folder delete warning")

        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(app.navigationBars["Exam 1"].appears(timeout: 5), "the deleted folder's screen leaves")
        let line = app.staticTexts["undo.line"]
        XCTAssertTrue(line.appears(timeout: 5))
        XCTAssertEqual(line.label, "Week 2 and its 2 sets deleted.")
        XCTAssertTrue(app.buttons["folder.Week 2"].disappears(timeout: 5))
        XCTAssertTrue(app.buttons["folder.Week 1"].exists)
        attachLooks(app, "folder deleted, Undo")

        app.buttons["undo.button"].tap()
        waitForLabel(line, containing: "Week 2 and its 2 sets are back.")
        XCTAssertTrue(app.buttons["folder.Week 2"].appears(timeout: 5), "back on Exam 1")
        attach(app, "folder back")
        XCTAssertTrue(app.otherElements["undo.bar"].disappears(timeout: 6), "the bar goes by itself")
    }

    /// A set is deleted from its row, and Recently deleted brings it back.
    @MainActor
    func testDeletingASetFromItsRowAndBringingItBackFromRecentlyDeleted() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        XCTAssertTrue(app.staticTexts["Touch and hold a set to delete it."].exists)
        let row = app.buttons["course.set.Mixed Clinical Judgment"]
        XCTAssertTrue(row.appears(timeout: 5))
        row.press(forDuration: 1.2)
        let delete = menuItem(app, "delete.Mixed Clinical Judgment", "Delete")
        XCTAssertTrue(delete.appears(timeout: 5))
        attach(app, "set touch and hold")
        chooseFromMenu(delete)

        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Delete Mixed Clinical Judgment?")
        XCTAssertTrue(app.staticTexts["deleteSheet.message"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["deleteSheet.message"].label, "Its 8 questions go with it. You can undo this for 30 days.")
        attach(app, "set delete warning")
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(row.disappears(timeout: 5))
        XCTAssertEqual(app.staticTexts["undo.line"].label, "Mixed Clinical Judgment deleted.")
        XCTAssertTrue(app.staticTexts["No sets yet. Move sets here from another folder."].appears(timeout: 5))

        goBack(app, from: "Weeks 1-3")
        open(app.buttons["course.recentlyDeleted"], titled: "Recently deleted", in: app)
        let bringBack = app.buttons["deleted.bringBack.Mixed Clinical Judgment"]
        XCTAssertTrue(bringBack.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Weeks 1-3 · 8 questions"].exists)
        attachLooks(app, "recently deleted")

        bringBack.tap()
        XCTAssertTrue(app.staticTexts["Mixed Clinical Judgment is back."].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nothing deleted in the last 30 days."].appears(timeout: 5))
        attach(app, "recently deleted, brought back")
        goBack(app, from: "Recently deleted")
        openFolder(app, "Weeks 1-3")
        XCTAssertTrue(row.appears(timeout: 5), "back in its folder")
    }

    /// A past exam is deleted from its row on Exam setup, and Undo lists it again.
    @MainActor
    func testDeletingAPastExamFromExamSetup() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let tile = app.buttons["course.tile.exam"]
        XCTAssertTrue(tile.appears(timeout: 5))
        tile.tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        let past = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "exam.past."))
        XCTAssertTrue(past.firstMatch.appears(timeout: 5))
        XCTAssertEqual(past.count, 3)
        let first = past.firstMatch
        let id = first.identifier
        reveal(first, in: app)
        XCTAssertTrue(app.staticTexts["Touch and hold an exam to delete it."].exists)
        first.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "delete.exam", "Delete"))

        XCTAssertTrue(app.staticTexts["deleteSheet.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["deleteSheet.title"].label, "Delete this exam?")
        let message = app.staticTexts["deleteSheet.message"]
        XCTAssertTrue(message.appears(timeout: 5))
        XCTAssertTrue(message.label.hasSuffix("You can undo this for 30 days."), message.label)
        attachLooks(app, "past exam delete warning")
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(app.buttons[id].disappears(timeout: 5))
        XCTAssertEqual(app.staticTexts["undo.line"].label, "Exam deleted.")
        XCTAssertEqual(past.count, 2)
        attach(app, "past exam deleted, Undo")

        app.buttons["undo.button"].tap()
        XCTAssertTrue(app.buttons[id].appears(timeout: 5))
        waitForLabel(app.staticTexts["undo.line"], containing: "The exam is back.")
        XCTAssertEqual(past.count, 3)
    }

    /// An exam in progress asks the folder's questions: the warning says so in the server's words,
    /// and Delete waits.
    @MainActor
    func testADeleteRefusedForNowSaysWhyAndWaits() throws {
        let app = launch("exam-in-progress")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        app.buttons["folder.delete"].tap()
        let problem = app.staticTexts["An exam in progress asks questions from Week 2. Finish or leave that exam first."]
        XCTAssertTrue(problem.appears(timeout: 5))
        XCTAssertFalse(app.buttons["deleteSheet.confirm"].isEnabled, "Delete waits")
        attachLooks(app, "delete refused for now")
        tapWhenStill(app.buttons["deleteSheet.cancel"])
        XCTAssertTrue(app.navigationBars["Week 2"].appears(timeout: 5), "nothing was deleted")
        XCTAssertFalse(app.otherElements["undo.bar"].exists)
    }
}
