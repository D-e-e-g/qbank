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

        app.buttons["folder.more"].tap()
        chooseFromMenu(menuItem(app, "folder.more.delete", "Delete folder"))
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
        XCTAssertTrue(app.staticTexts["No sets yet. Import a question file here, or move sets here from another folder."].appears(timeout: 5))

        goBack(app, from: "Weeks 1-3")
        openRecentlyDeleted(app)
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

    /// One ticked set: Delete beside Move reads as its own warning, the selection ends, and Undo
    /// brings it back.
    @MainActor
    func testDeletingOneTickedSetFromTheSelectBar() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        let set = "Therapeutic Communication and the Relationship"

        app.buttons["folder.select"].tap()
        XCTAssertFalse(app.buttons["folder.deleteSets"].exists, "nothing ticked yet")
        app.buttons["folder.pick.\(set)"].tap()
        let delete = app.buttons["folder.deleteSets"]
        XCTAssertTrue(delete.appears(timeout: 5))
        XCTAssertEqual(delete.label, "Delete 1 set")
        XCTAssertLessThan(delete.frame.maxX, app.buttons["folder.move"].frame.minX, "beside Move")
        attachLooks(app, "select bar, one set")

        delete.tap()
        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        waitForLabel(title, containing: "Delete \(set)?")
        XCTAssertTrue(app.staticTexts["deleteSheet.message"].appears(timeout: 5))
        tapWhenStill(app.buttons["deleteSheet.confirm"])

        XCTAssertTrue(app.buttons["course.set.\(set)"].disappears(timeout: 5))
        XCTAssertEqual(app.staticTexts["undo.line"].label, "\(set) deleted.")
        XCTAssertFalse(app.buttons["folder.move"].exists, "selecting ended")
        XCTAssertEqual(app.buttons["folder.select"].label, "Select sets")
        XCTAssertTrue(app.buttons["course.set.Psychosocial Assessment and Safety Screening"].exists)
        app.buttons["undo.button"].tap()
        XCTAssertTrue(app.buttons["course.set.\(set)"].appears(timeout: 5))
    }

    /// Several ticked sets: one warning names each, they go together, and one Undo brings them all back.
    @MainActor
    func testDeletingSeveralTickedSetsFromTheSelectBar() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        let sets = ["Therapeutic Communication and the Relationship", "Psychosocial Assessment and Safety Screening"]

        app.buttons["folder.select"].tap()
        for set in sets {
            app.buttons["folder.pick.\(set)"].tap()
        }
        let delete = app.buttons["folder.deleteSets"]
        XCTAssertTrue(delete.appears(timeout: 5))
        XCTAssertEqual(delete.label, "Delete 2 sets")
        XCTAssertEqual(app.buttons["folder.move"].label, "Move 2 sets")
        attachLooks(app, "select bar, two sets")

        delete.tap()
        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Delete 2 sets?")
        let message = app.staticTexts["deleteSheet.message"]
        XCTAssertTrue(message.appears(timeout: 5))
        for set in sets {
            XCTAssertTrue(message.label.contains(set), message.label)
        }
        attachLooks(app, "delete two sets warning")
        tapWhenStill(app.buttons["deleteSheet.confirm"])

        XCTAssertTrue(app.staticTexts["No sets yet. Import a question file here, or move sets here from another folder."].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["undo.line"].label, "2 sets deleted.")
        XCTAssertFalse(app.buttons["folder.move"].exists, "selecting ended")
        attachLooks(app, "two sets deleted")

        app.buttons["undo.button"].tap()
        for set in sets {
            XCTAssertTrue(app.buttons["course.set.\(set)"].appears(timeout: 5))
        }
        waitForLabel(app.staticTexts["undo.line"], containing: "2 sets are back.")
    }

    /// An exam in progress asks the ticked sets' questions: the warning says why for each, Delete
    /// waits, and she is still selecting when she cancels.
    @MainActor
    func testTickedSetsARefusalSaysWhyAndWaits() throws {
        let app = launch("exam-in-progress")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        let sets = ["Therapeutic Communication and the Relationship", "Psychosocial Assessment and Safety Screening"]
        app.buttons["folder.select"].tap()
        for set in sets {
            app.buttons["folder.pick.\(set)"].tap()
        }
        app.buttons["folder.deleteSets"].tap()
        let problem = app.staticTexts["problem"]
        XCTAssertTrue(problem.appears(timeout: 5))
        waitForLabel(problem, containing: "An exam in progress asks questions from \(sets[0]).")
        XCTAssertTrue(problem.label.contains(sets[1]), problem.label)
        XCTAssertFalse(app.buttons["deleteSheet.confirm"].isEnabled, "Delete waits")
        attachLooks(app, "delete two sets refused")
        tapWhenStill(app.buttons["deleteSheet.cancel"])
        XCTAssertTrue(app.buttons["folder.move"].appears(timeout: 5), "still selecting, nothing was deleted")
        XCTAssertFalse(app.otherElements["undo.bar"].exists)
    }

    /// An exam in progress asks the folder's questions: the warning says so in the server's words,
    /// and Delete waits.
    @MainActor
    func testADeleteRefusedForNowSaysWhyAndWaits() throws {
        let app = launch("exam-in-progress")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        app.buttons["folder.more"].tap()
        chooseFromMenu(menuItem(app, "folder.more.delete", "Delete folder"))
        let problem = app.staticTexts["An exam in progress asks questions from Week 2. Finish or leave that exam first."]
        XCTAssertTrue(problem.appears(timeout: 5))
        XCTAssertFalse(app.buttons["deleteSheet.confirm"].isEnabled, "Delete waits")
        attachLooks(app, "delete refused for now")
        tapWhenStill(app.buttons["deleteSheet.cancel"])
        XCTAssertTrue(app.navigationBars["Week 2"].appears(timeout: 5), "nothing was deleted")
        XCTAssertFalse(app.otherElements["undo.bar"].exists)
    }
}
