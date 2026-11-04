import XCTest

/// Deleting an exam page from its editor: the page alone goes, after a warning in the server's
/// words, and its folders stay in the course with their sets; Recently deleted brings it back with
/// its folders; and the server's refusals, for the delete and for Undo. End to end against the
/// in-process fake server of the Debug launch seam, with invented questions and accounts only.
final class ExamPageDeletionUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testDeletingAnExamPageKeepsItsFoldersAndRecentlyDeletedBringsItBack() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openEditor(app, "Exam 1")
        let delete = app.buttons["editPage.delete"]
        reveal(delete, in: app)
        XCTAssertEqual(delete.label, "Delete this page")
        attachLooks(app, "exam page editor, Delete")

        tapWhenStill(delete)
        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Delete Exam 1?")
        let message = app.staticTexts["deleteSheet.message"]
        XCTAssertTrue(message.appears(timeout: 5))
        XCTAssertEqual(
            message.label,
            "Its 2 folders stay, with their sets and your progress, under Folders: Week 1 and Week 2. Your 2 past exams over it stay. You can undo this for 30 days."
        )
        XCTAssertTrue(app.buttons["deleteSheet.confirm"].isEnabled)
        attachLooks(app, "exam page delete warning")

        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5), "the deleted page's screen leaves")
        let line = app.staticTexts["undo.line"]
        XCTAssertTrue(line.appears(timeout: 5))
        XCTAssertEqual(line.label, "Exam 1 deleted.")
        XCTAssertTrue(app.buttons["course.page.Exam 1"].disappears(timeout: 5))
        XCTAssertTrue(app.buttons["folder.Week 1"].exists, "its folders are under Folders")
        XCTAssertTrue(app.buttons["folder.Week 2"].exists)
        attachLooks(app, "exam page deleted, its folders under Folders")
        XCTAssertTrue(app.otherElements["undo.bar"].disappears(timeout: 8))

        // Its folders keep their sets meanwhile.
        openFolder(app, "Week 2")
        XCTAssertTrue(app.buttons["course.set.Therapeutic Communication and the Relationship"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.set.Psychosocial Assessment and Safety Screening"].exists)
        goBack(app, from: "Week 2")

        open(app.buttons["course.recentlyDeleted"], titled: "Recently deleted", in: app)
        let bringBack = app.buttons["deleted.bringBack.Exam 1"]
        XCTAssertTrue(bringBack.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pages"].exists)
        XCTAssertTrue(app.staticTexts["Week 1, Week 2"].exists, "the folders Bring back puts back on it")
        attachLooks(app, "recently deleted, an exam page")

        bringBack.tap()
        XCTAssertTrue(app.staticTexts["Exam 1 is back."].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nothing deleted in the last 30 days."].appears(timeout: 5))
        goBack(app, from: "Recently deleted")
        XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["folder.Week 1"].disappears(timeout: 5), "back on the page")
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        XCTAssertTrue(app.buttons["folder.Week 1"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["folder.Week 2"].exists)
        attach(app, "exam page back with its folders")
    }

    /// A folder in the Folders list has the name of one of its folders: Delete waits, with why.
    @MainActor
    func testAnExamPageWhoseFolderNameIsInTheFoldersListSaysWhy() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.folder", "New folder"))
        let name = app.textFields["newFolder.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText("Week 2")
        app.buttons["newFolder.save"].tap()
        XCTAssertTrue(name.disappears(timeout: 10))

        openEditor(app, "Exam 1")
        tapVisible(app.buttons["editPage.delete"], in: app)
        let refusal = app.staticTexts["NURS 310 already has a folder named Week 2 in its Folders list. Rename one of them before deleting Exam 1."]
        XCTAssertTrue(refusal.appears(timeout: 5))
        XCTAssertFalse(app.buttons["deleteSheet.confirm"].isEnabled, "Delete waits")
        attachLooks(app, "exam page delete refused")
        tapWhenStill(app.buttons["deleteSheet.cancel"])
        XCTAssertTrue(app.navigationBars["Exam 1"].appears(timeout: 5), "nothing was deleted")
        XCTAssertFalse(app.otherElements["undo.bar"].exists)
    }

    /// Another page has its name now: Recently deleted says so, and Bring back waits.
    @MainActor
    func testADeletedExamPageWhoseNameIsTakenWaitsInRecentlyDeleted() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openEditor(app, "Exam 2")
        tapVisible(app.buttons["editPage.delete"], in: app)
        XCTAssertTrue(app.staticTexts["deleteSheet.message"].appears(timeout: 5))
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(app.buttons["course.page.Exam 2"].disappears(timeout: 5))
        XCTAssertTrue(app.otherElements["undo.bar"].disappears(timeout: 8))

        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
        let name = app.textFields["editPage.name"]
        XCTAssertEqual(name.value as? String, "Page 2")
        name.clearText()
        name.typeText("Exam 2")
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Exam 2"].appears(timeout: 10))
        goBack(app, from: "Exam 2")

        open(app.buttons["course.recentlyDeleted"], titled: "Recently deleted", in: app)
        let refusal = app.staticTexts["This course already has an exam named Exam 2. Rename one of them, then bring this one back."]
        XCTAssertTrue(refusal.appears(timeout: 5))
        XCTAssertFalse(app.buttons["deleted.bringBack.Exam 2"].isEnabled)
        attachLooks(app, "recently deleted, exam page name taken")
    }

    /// Opens an exam page from the course page, then Edit and Name and folders: its editor.
    @MainActor
    private func openEditor(_ app: XCUIApplication, _ page: String) {
        open(app.buttons["course.page.\(page)"], titled: page, in: app)
        app.buttons["page.edit"].tap()
        tapWhenStill(app.buttons["page.editPage"])
        XCTAssertTrue(app.navigationBars["Edit \(page)"].appears(timeout: 5))
    }
}
