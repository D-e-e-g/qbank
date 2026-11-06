import XCTest

/// The Add tab: Import (3-1 to 3-3) end to end against the in-process fake server of the Debug
/// launch seam, which checks and files question files with the server's rules and words.
/// Invented question files and accounts only.
final class AddUITests: XCTestCase {
    /// A small invented question file: two single-answer questions and one select-all, one term.
    static let file = #"{"title":"Invented Sleep and Rest","desc":"Invented practice questions.","terms":{"sleep-hygiene":["Sleep hygiene","Habits that help sleep."]},"questions":[{"id":"S1","type":"single","topic":"Bedtime","cj":"Take action","need":"Basic care","diff":2,"src":"Invented notes","stem":"An invented client has trouble sleeping.","ask":"Which advice helps?","options":[{"t":"Keep a regular bedtime","ok":true},{"t":"Nap in the evening"},{"t":"Coffee at night"}],"rationale":"Invented.","takeaway":"Invented.","terms":["sleep-hygiene"]},{"id":"S2","type":"sata","topic":"Room","cj":"Take action","need":"Basic care","diff":2,"src":"Invented notes","stem":"An invented client asks about the bedroom.","ask":"Which help? Select all that apply.","options":[{"t":"Dim the lights","ok":true},{"t":"Limit caffeine","ok":true},{"t":"Screens on"}],"rationale":"Invented.","takeaway":"Invented."},{"id":"S3","type":"single","topic":"Naps","cj":"Analyze cues","need":"Basic care","diff":3,"src":"Invented notes","stem":"An invented client naps at 6 PM.","ask":"What is the concern?","options":[{"t":"It delays sleep","ok":true},{"t":"None"},{"t":"It helps sleep"}],"rationale":"Invented.","takeaway":"Invented."}]}"#

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Import (3-1, 3-2, 3-3)

    @MainActor
    func testImportIntoUnsortedThenReplace() throws {
        let app = launch("signed-in")
        openImport(app)
        XCTAssertTrue(app.buttons["Choose file"].isSelected)
        XCTAssertTrue(app.buttons["import.file"].label.contains("Choose a JSON file"))
        XCTAssertTrue(app.staticTexts["From Files or iCloud Drive."].exists)
        waitForLabel(app.buttons["import.course"], containing: "NURS 310 · Mental Health")
        XCTAssertTrue(app.buttons["import.folder.Unsorted"].isSelected, "Unsorted is picked unless she picks a folder")
        XCTAssertTrue(app.buttons["import.folder.Unsorted"].label.contains("new"), "made on first use")
        XCTAssertTrue(app.buttons["import.folder.Exam 1.Week 1"].exists)
        XCTAssertTrue(app.buttons["import.folder.Folders.Weeks 1-3"].exists)
        XCTAssertFalse(app.buttons["import.check"].isEnabled, "nothing to check yet")
        attachLooks(app, "3-1 import")

        paste(Self.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        let ready = app.descendants(matching: .any)["import.ready"]
        XCTAssertTrue(ready.appears(timeout: 5))
        XCTAssertEqual(ready.label, "Ready: 3 questions, 1 term")
        XCTAssertTrue(app.staticTexts["2 Single answer"].exists)
        XCTAssertTrue(app.staticTexts["1 Select all that apply"].exists)
        XCTAssertEqual(app.textFields["import.title"].value as? String, "Invented Sleep and Rest", "filled from the file's title")
        attachLooks(app, "3-2 import checked")

        tapVisible(app.buttons["import.commit"], in: app)
        let title = app.staticTexts["import.done.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Imported")
        XCTAssertEqual(
            app.staticTexts["import.done.copy"].label,
            "“Invented Sleep and Rest” · 3 questions in NURS 310, Unsorted. It is in the course’s Folders list until you move it."
        )
        attachLooks(app, "3-3 imported")

        // The same name again asks first, in the web's words.
        app.buttons["import.done.another"].tap()
        XCTAssertTrue(app.buttons["import.check"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["import.folder.Unsorted"].isSelected)
        XCTAssertFalse(app.buttons["import.folder.Unsorted"].label.contains("new"), "Unsorted exists now")
        paste(Self.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        XCTAssertTrue(app.buttons["import.commit"].appears(timeout: 5))
        tapVisible(app.buttons["import.commit"], in: app)
        let sheet = app.staticTexts["import.replace.title"]
        XCTAssertTrue(sheet.appears(timeout: 5))
        XCTAssertEqual(sheet.label, "Replace “Invented Sleep and Rest”?")
        XCTAssertEqual(
            app.staticTexts["import.replace.message"].label,
            "NURS 310, Unsorted already has a set with this name. Replacing swaps its 3 questions for the 3 in this file, and it stays in Unsorted. Answers on unchanged questions are kept, and the old version stays restorable."
        )
        XCTAssertTrue(app.buttons["import.replace.separate"].exists)
        XCTAssertTrue(app.buttons["import.replace.cancel"].exists)
        attachLooks(app, "3-2 replace sheet")
        app.buttons["import.replace.confirm"].tap()
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertEqual(title.label, "Replaced")
        XCTAssertTrue(app.staticTexts["import.done.copy"].label.hasSuffix("The previous version can be restored from its folder."))
        attachLooks(app, "3-3 replaced")

        // Open Unsorted shows the set in its folder on Home.
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        XCTAssertTrue(tabButton(app, "Home").isSelected)
        XCTAssertTrue(app.buttons["course.set.Invented Sleep and Rest"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.restore"].exists, "the replaced set offers its previous version")
        attachLooks(app, "3-3 open unsorted")
    }

    @MainActor
    func testImportHereFromAFolder() throws {
        let app = launch("signed-in")
        openFolder(app, "Weeks 1-3")
        let importHere = app.buttons["folder.add"]
        XCTAssertTrue(importHere.appears(timeout: 5))
        XCTAssertEqual(importHere.label, "Import here")
        XCTAssertFalse(app.buttons["folder.import"].exists, "a folder with sets has no card")
        attachLooks(app, "folder with import here")
        importHere.tap()
        XCTAssertTrue(app.buttons["import.folder.Folders.Weeks 1-3"].appears(timeout: 5))
        waitForSelected(app.buttons["import.folder.Folders.Weeks 1-3"])
        XCTAssertFalse(app.buttons["import.folder.Unsorted"].isSelected)
        waitForLabel(app.buttons["import.course"], containing: "NURS 310 · Mental Health")
        app.buttons["Paste JSON"].tap()
        paste(Self.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        XCTAssertTrue(app.buttons["import.commit"].appears(timeout: 5))
        tapVisible(app.buttons["import.commit"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.copy"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["import.done.copy"].label, "“Invented Sleep and Rest” · 3 questions in NURS 310, Weeks 1-3.")
        attachLooks(app, "import here done")
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Weeks 1-3"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.set.Invented Sleep and Rest"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.set.Mixed Clinical Judgment"].exists)
    }

    @MainActor
    func testAFileWithErrorsSaysWhatToFix() throws {
        let app = launch("signed-in")
        openImport(app)
        app.buttons["Paste JSON"].tap()
        paste(#"{"title":"Broken","questions":[{"id":"B1","type":"single","stem":"Invented.","ask":"Which?","options":[{"t":"One","ok":true},{"t":"Two","ok":true},{"t":"Three"}],"rationale":"Invented."}]}"#, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        let errors = app.descendants(matching: .any)["import.errors"]
        XCTAssertTrue(errors.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Question 1 (B1): missing takeaway"].exists)
        XCTAssertTrue(app.staticTexts["Question 1 (B1): needs exactly one option with \"ok\": true (found 2)"].exists)
        XCTAssertFalse(app.buttons["import.commit"].exists, "a file with errors cannot be imported")
        tapVisible(app.buttons["import.copyErrors"], in: app)
        XCTAssertTrue(app.buttons["Copied"].appears(timeout: 5))
        attachLooks(app, "3-2 file with errors")
    }

    @MainActor
    func testImportNeedsAConnection() throws {
        let app = launch("signed-in", online: false)
        openImport(app)
        XCTAssertTrue(app.descendants(matching: .any)["import.offline"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["import.check"].isEnabled)
        attachLooks(app, "import offline")
    }

    // MARK: Helpers

    @MainActor
    private func openImport(_ app: XCUIApplication) {
        openTab(app, "Add")
        XCTAssertTrue(app.navigationBars["Add questions"].appears(timeout: 5))
        app.buttons["add.import"].tap()
        XCTAssertTrue(app.navigationBars["Import"].appears(timeout: 5))
    }
}
