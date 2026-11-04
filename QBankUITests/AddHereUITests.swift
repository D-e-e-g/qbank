import XCTest

/// One + per screen, adding into that screen, and holding a course or topic on Home, end to end
/// against the in-process fake server of the Debug launch seam: Home's + (a course, a topic, a
/// semester), a held card's Open, Rename, Move and Archive, Unarchive in Archived, a course's +
/// (Import, New folder, New exam page, Make questions) and an exam page's + (Import here, New folder
/// on this page, Add existing folders). Invented courses, topics and question files only.
final class AddHereUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Home's +

    @MainActor
    func testHomesPlusAddsASemesterACourseAndATopic() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        openHome(app)
        XCTAssertTrue(app.staticTexts["No courses yet. Tap + to add one, or import its first question file."].exists)
        XCTAssertFalse(app.buttons["home.newTopic"].exists, "no New on Study topics")
        attachLooks(app, "A-1 home")

        // The menu: a course in each semester she studies, a topic, and the missing semester.
        let plus = app.buttons["home.add"]
        plus.tap()
        XCTAssertTrue(menuItem(app, "home.add.course.1", "New course in Semester 1").appears(timeout: 5))
        XCTAssertTrue(menuItem(app, "home.add.course.2", "New course in Semester 2").exists)
        XCTAssertTrue(menuItem(app, "home.add.topic", "New study topic").exists)
        XCTAssertTrue(menuItem(app, "home.add.semester", "Add Semester 3").exists)
        attachLooks(app, "M-1 home, the + menu")

        // Add Semester 3: it shows on Home, and the + offers no more.
        chooseFromMenu(menuItem(app, "home.add.semester", "Add Semester 3"))
        XCTAssertTrue(app.staticTexts["SEMESTER 3"].appears(timeout: 5) || app.staticTexts["Semester 3"].appears(timeout: 1))
        plus.tap()
        XCTAssertTrue(menuItem(app, "home.add.course.3", "New course in Semester 3").appears(timeout: 5))
        XCTAssertFalse(menuItem(app, "home.add.semester", "Add Semester 3").exists, "there are only three")

        // New course in Semester 2: a code the semester has is refused in the server's words, and
        // Done opens the course, empty, with its +.
        chooseFromMenu(menuItem(app, "home.add.course.2", "New course in Semester 2"))
        XCTAssertTrue(app.navigationBars["New course in Semester 2"].appears(timeout: 5))
        let code = app.textFields["newCourse.code"]
        XCTAssertTrue(code.appears(timeout: 5))
        code.typeText("NURS 406")
        app.textFields["newCourse.title"].tap()
        app.textFields["newCourse.title"].typeText("Invented Pediatrics")
        attachLooks(app, "home, new course")
        app.buttons["newCourse.save"].tap()
        XCTAssertTrue(app.navigationBars["NURS 406"].appears(timeout: 10), "the new course opens")
        XCTAssertTrue(app.staticTexts["This course has no question sets yet."].exists)
        XCTAssertTrue(app.buttons["course.add"].exists)
        goBack(app, from: "NURS 406")
        XCTAssertTrue(app.buttons["home.course.NURS 406"].appears(timeout: 5))

        plus.tap()
        chooseFromMenu(menuItem(app, "home.add.course.2", "New course in Semester 2"))
        XCTAssertTrue(code.appears(timeout: 5))
        code.typeText("nurs 406")
        app.textFields["newCourse.title"].tap()
        app.textFields["newCourse.title"].typeText("Again")
        app.buttons["newCourse.save"].tap()
        XCTAssertTrue(app.staticTexts["This semester already has a course with the code nurs 406."].appears(timeout: 5))
        tapWhenStill(app.buttons["newCourse.cancel"])
        XCTAssertTrue(code.disappears(timeout: 5))

        // New study topic is the topic sheet; Done opens the topic.
        plus.tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText("Invented Pharmacology")
        tapWhenStill(app.buttons["newTopic.save"])
        XCTAssertTrue(app.navigationBars["Invented Pharmacology"].appears(timeout: 10))
    }

    @MainActor
    func testHomesPlusWaitsForAConnection() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        openHome(app)
        XCTAssertTrue(app.buttons["home.add"].isEnabled)
        setNetwork(online: false)
        app.swipeDown()
        let offline = app.descendants(matching: .any)["home.offline"]
        XCTAssertTrue(offline.appears(timeout: 10))
        XCTAssertFalse(app.buttons["home.add"].isEnabled, "adding needs QBank")
        setNetwork(online: true)
    }

    // MARK: Holding a card

    @MainActor
    func testHoldingACourseRenamesMovesArchivesAndUnarchivesIt() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        openHome(app)
        let fundamentals = app.buttons["home.course.NURS 220"]
        XCTAssertTrue(fundamentals.appears(timeout: 5))

        // Open, Rename, Move to the other semester, Archive, and Delete last.
        fundamentals.press(forDuration: 1.2)
        XCTAssertTrue(menuItem(app, "home.hold.open", "Open").appears(timeout: 5))
        XCTAssertTrue(menuItem(app, "home.hold.rename", "Rename").exists)
        XCTAssertTrue(menuItem(app, "home.hold.move.2", "Move to Semester 2").exists)
        XCTAssertFalse(menuItem(app, "home.hold.move.1", "Move to Semester 1").exists, "not its own semester")
        XCTAssertTrue(menuItem(app, "home.hold.archive", "Archive").exists)
        XCTAssertTrue(menuItem(app, "home.hold.delete", "Delete").exists)
        XCTAssertGreaterThan(menuItem(app, "home.hold.delete", "Delete").frame.minY, menuItem(app, "home.hold.archive", "Archive").frame.minY, "after Archive")
        attachLooks(app, "M-3 home, holding a card")
        chooseFromMenu(menuItem(app, "home.hold.open", "Open"))
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 5))
        goBack(app, from: "NURS 220")

        // Rename: only its name changes.
        fundamentals.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "home.hold.rename", "Rename"))
        XCTAssertTrue(app.navigationBars["Rename course"].appears(timeout: 5))
        let code = app.textFields["renameCourse.code"]
        XCTAssertEqual(code.value as? String, "NURS 220")
        code.clearAndType("NURS 221")
        attachLooks(app, "home, rename course")
        app.buttons["renameCourse.save"].tap()
        let renamed = app.buttons["home.course.NURS 221"]
        XCTAssertTrue(renamed.appears(timeout: 10))
        XCTAssertFalse(fundamentals.exists)

        // Move it to Semester 2: it leaves Semester 1's list for Semester 2's.
        let mentalHealth = app.buttons["home.course.NURS 310"]
        XCTAssertLessThan(renamed.frame.minY - mentalHealth.frame.minY, 400)
        renamed.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "home.hold.move.2", "Move to Semester 2"))
        XCTAssertTrue(app.staticTexts["No courses yet. Tap + to add one, or import its first question file."].disappears(timeout: 10), "Semester 2 has it")
        XCTAssertTrue(renamed.exists)

        // Archive asks nothing: it goes to Archived, closed, and Unarchive brings it back.
        renamed.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "home.hold.archive", "Archive"))
        XCTAssertTrue(renamed.disappears(timeout: 10))
        XCTAssertFalse(app.staticTexts["deleteSheet.title"].exists, "no question first")
        let archived = app.buttons["home.archived"]
        tapVisible(archived, in: app)
        XCTAssertEqual(archived.value as? String, "Open")
        reveal(renamed, in: app)
        renamed.press(forDuration: 1.2)
        XCTAssertTrue(menuItem(app, "home.hold.unarchive", "Unarchive").appears(timeout: 5))
        XCTAssertFalse(menuItem(app, "home.hold.archive", "Archive").exists)
        attachLooks(app, "home, holding an archived card")
        chooseFromMenu(menuItem(app, "home.hold.unarchive", "Unarchive"))
        XCTAssertTrue(archived.disappears(timeout: 10), "nothing is archived anymore")
        XCTAssertTrue(renamed.appears(timeout: 5))
    }

    // MARK: A course's +

    @MainActor
    func testACoursesPlusImportsMakesAFolderAndAPage() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        openHome(app)
        open(app.buttons["home.course.NURS 220"], titled: "NURS 220", in: app)
        XCTAssertTrue(app.staticTexts["No pages yet. Tap + to make Page 1."].appears(timeout: 5))
        XCTAssertFalse(app.buttons["course.newPage"].exists, "no New on Pages")
        attachLooks(app, "A-2 course")

        let plus = app.buttons["course.add"]
        plus.tap()
        XCTAssertTrue(app.staticTexts["Add to NURS 220"].appears(timeout: 5))
        XCTAssertTrue(menuItem(app, "course.add.import", "Import a question file").exists)
        XCTAssertFalse(menuItem(app, "course.add.make", "Make questions").exists, "the server does not let this account make questions")
        XCTAssertTrue(menuItem(app, "course.add.folder", "New folder").exists)
        XCTAssertTrue(menuItem(app, "course.add.page", "New page").exists)
        attachLooks(app, "M-2 course, the + menu")

        // New folder: it is listed under Folders.
        chooseFromMenu(menuItem(app, "course.add.folder", "New folder"))
        let name = app.textFields["newFolder.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText("Week 4")
        app.buttons["newFolder.save"].tap()
        XCTAssertTrue(name.disappears(timeout: 10))
        XCTAssertTrue(app.buttons["folder.Week 4"].appears(timeout: 5))

        // Import a question file: the course is picked, with Unsorted and its folders as chips;
        // Open goes to the folder, back inside the course.
        plus.tap()
        chooseFromMenu(menuItem(app, "course.add.import", "Import a question file"))
        XCTAssertTrue(app.buttons["import.check"].appears(timeout: 5))
        waitForLabel(app.buttons["import.course"], containing: "NURS 220 · Fundamentals")
        XCTAssertTrue(app.buttons["import.folder.Unsorted"].isSelected)
        let week4 = app.buttons["import.folder.Folders.Week 4"]
        XCTAssertTrue(week4.appears(timeout: 5))
        week4.tap()
        paste(AddUITests.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        XCTAssertTrue(app.buttons["import.commit"].appears(timeout: 5))
        tapVisible(app.buttons["import.commit"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["import.done.copy"].label, "“Invented Sleep and Rest” · 3 questions in NURS 220, Week 4.")
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Week 4"].appears(timeout: 10))
        XCTAssertTrue(app.buttons["course.set.Invented Sleep and Rest"].appears(timeout: 5))
        goBack(app, from: "Week 4")

        // New page is the page editor; the page opens.
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 5))
        plus.tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
        app.buttons["editPage.chip.free.Week 4"].tap()
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Page 1"].appears(timeout: 10))
    }

    @MainActor
    func testMakeQuestionsFromACourseStartsWithItPicked() throws {
        try skipOnIPad()
        let app = launch("maker")
        openHome(app)
        open(app.buttons["home.course.NURS 220"], titled: "NURS 220", in: app)
        app.buttons["course.add"].tap()
        let make = menuItem(app, "course.add.make", "Make questions")
        XCTAssertTrue(make.appears(timeout: 5))
        chooseFromMenu(make)
        XCTAssertTrue(app.navigationBars["Your material"].appears(timeout: 5))
        waitForLabel(app.buttons["import.course"], containing: "NURS 220 · Fundamentals")
        XCTAssertTrue(app.buttons["import.folder.Unsorted"].isSelected)
        attachLooks(app, "course, make questions")
    }

    // MARK: An exam page's +

    @MainActor
    func testAnExamPagesPlusImportsHereAndMakesAFolderOnIt() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        XCTAssertTrue(app.staticTexts["Study material"].exists)
        XCTAssertTrue(app.buttons["page.edit"].exists, "Edit stays for the page's name and folders")
        attachLooks(app, "A-3 exam page")

        let plus = app.buttons["page.add"]
        plus.tap()
        XCTAssertTrue(app.staticTexts["Add to Exam 1"].appears(timeout: 5))
        XCTAssertTrue(menuItem(app, "page.add.import", "Import a question file here").exists)
        XCTAssertTrue(menuItem(app, "page.add.folder", "New folder on this page").exists)
        XCTAssertTrue(menuItem(app, "page.add.existing", "Add existing folders").exists)
        attachLooks(app, "exam page, the + menu")

        // Add existing folders is the page's editor, with her folders as chips.
        chooseFromMenu(menuItem(app, "page.add.existing", "Add existing folders"))
        XCTAssertTrue(app.navigationBars["Edit Exam 1"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["editPage.chip.free.Weeks 1-3"].exists)
        tapWhenStill(app.buttons["editPage.cancel"])
        XCTAssertTrue(app.navigationBars["Edit Exam 1"].disappears(timeout: 5))

        // New folder on this page makes it and puts it on the page in one step.
        plus.tap()
        chooseFromMenu(menuItem(app, "page.add.folder", "New folder on this page"))
        XCTAssertTrue(app.navigationBars["New folder on Exam 1"].appears(timeout: 5))
        let name = app.textFields["newFolder.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText("Week 1b")
        app.buttons["newFolder.save"].tap()
        XCTAssertTrue(name.disappears(timeout: 10))
        XCTAssertTrue(app.buttons["folder.Week 1b"].appears(timeout: 5))

        // Import here: the course is picked, this page's folders come first, its first one picked.
        plus.tap()
        chooseFromMenu(menuItem(app, "page.add.import", "Import a question file here"))
        XCTAssertTrue(app.buttons["import.check"].appears(timeout: 5))
        waitForLabel(app.buttons["import.course"], containing: "NURS 310 · Mental Health")
        let first = app.buttons["import.folder.Exam 1.Week 1"]
        XCTAssertTrue(first.appears(timeout: 5))
        XCTAssertTrue(first.isSelected)
        XCTAssertLessThan(first.frame.minY, app.buttons["import.folder.Exam 2.Week 3"].frame.minY)
        app.buttons["import.folder.Exam 1.Week 1b"].tap()
        paste(AddUITests.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        XCTAssertTrue(app.buttons["import.commit"].appears(timeout: 5))
        tapVisible(app.buttons["import.commit"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["import.done.copy"].label, "“Invented Sleep and Rest” · 3 questions in NURS 310, Week 1b. It is on Exam 1.")
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Week 1b"].appears(timeout: 10))
        XCTAssertTrue(app.buttons["course.set.Invented Sleep and Rest"].appears(timeout: 5))
    }

    @MainActor
    func testImportHereOnAnEmptyPageMakesItsFolderOnThePage() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        openHome(app)
        open(app.buttons["home.course.NURS 220"], titled: "NURS 220", in: app)
        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Page 1"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["No folders on this page yet. Add the folders this page covers."].exists)

        app.buttons["page.add"].tap()
        chooseFromMenu(menuItem(app, "page.add.import", "Import a question file here"))
        XCTAssertTrue(app.buttons["import.check"].appears(timeout: 5))
        let newName = app.textFields["import.folder.newName"]
        XCTAssertTrue(newName.appears(timeout: 5), "a new folder, for the page")
        XCTAssertTrue(app.buttons["import.folder.new"].isSelected)
        paste(AddUITests.file, in: app)
        tapVisible(newName, in: app)
        newName.typeText("Week 5")
        tapVisible(app.buttons["import.check"], in: app)
        XCTAssertTrue(app.buttons["import.commit"].appears(timeout: 5))
        tapVisible(app.buttons["import.commit"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["import.done.copy"].label, "“Invented Sleep and Rest” · 3 questions in NURS 220, Week 5. It is on Page 1.")
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Week 5"].appears(timeout: 10))
        goBack(app, from: "Week 5")
        XCTAssertTrue(app.buttons["folder.Week 5"].appears(timeout: 5), "on the page")
    }

    /// Home's + left under the course she opened, once the Color changed, kept the signed-in
    /// screens from going at sign-out, and signing in again brought back the old ones, Settings
    /// and its spinning Sign out included.
    @MainActor
    func testSigningOutUnderAPlusAndInAgainStartsAfresh() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openTab(app, "Settings")
        let slate = app.buttons["Slate"]
        reveal(slate, in: app)
        slate.tap()
        XCTAssertTrue(slate.isSelected)
        app.swipeDown()
        let signOut = app.buttons["settings.signOut"]
        XCTAssertTrue(signOut.appears(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        signIn(app, email: "student@example.com", password: "synthetic-pass-1")
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "the course she used last, on fresh screens")
        XCTAssertTrue(tabButton(app, "Home").isSelected)
        XCTAssertTrue(app.buttons["course.add"].exists)
    }

    // MARK: Helpers

    /// The signed-in scenario opens her last course; Home is one step back.
    @MainActor
    private func openHome(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        goBack(app, from: "NURS 310")
        XCTAssertTrue(app.navigationBars["Home"].appears(timeout: 5))
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
