import XCTest

/// The iPad layout end to end: her courses stay in a sidebar beside the course she chose, and every
/// screen keeps a reading column however wide the iPad is, in both orientations, light and dark.
/// Skipped on iPhone, whose layout the other suites cover.
final class IPadUITests: XCTestCase {
    /// The reading column's widest, `QBankLayout.contentMax`.
    private static let contentMax: CGFloat = 720

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the iPad layout runs on iPad")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    @MainActor
    func testCoursesStayBesideTheCourseSheChose() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "lands on the course she used last")
        let mentalHealth = app.buttons["home.course.NURS 310"]
        let fundamentals = app.buttons["home.course.NURS 220"]
        XCTAssertTrue(mentalHealth.appears(timeout: 5))
        XCTAssertTrue(mentalHealth.isSelected, "the open course is marked in the list")
        let summary = app.descendants(matching: .any)["course.summary"]
        XCTAssertTrue(summary.appears(timeout: 5))
        XCTAssertLessThan(mentalHealth.frame.maxX, summary.frame.minX, "the course opens beside the list")
        expectReadingColumn(summary)

        // Deeper in the course, the list stays; another course opens on its own page.
        openFolder(app, "Week 2", on: "Exam 1")
        XCTAssertTrue(mentalHealth.isHittable)
        fundamentals.tap()
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 5))
        XCTAssertTrue(fundamentals.isSelected)
        XCTAssertFalse(mentalHealth.isSelected)

        mentalHealth.tap()
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5), "back on the course's own page")

        // Landscape keeps both columns, and the course's screens open beside the list.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(mentalHealth.appears(timeout: 5))
        XCTAssertTrue(mentalHealth.isHittable)
        expectReadingColumn(summary)
        app.buttons["course.tile.review"].tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))
        XCTAssertTrue(mentalHealth.isHittable)
    }

    /// A set she left midway picks up at its first unanswered question, its line in the reading
    /// column, and Start over asks once.
    @MainActor
    func testASetPicksUpWhereSheLeftIt() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        let row = app.buttons["course.set.Mixed Clinical Judgment"]
        tapVisible(row, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 10))
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 10))
        app.buttons["practice.close"].tap()

        XCTAssertTrue(row.appears(timeout: 10))
        waitForLabel(row, containing: "1 of 8 answered · Continue")
        attachLooks(app, "iPad set progress, the row")
        tapVisible(row, in: app)
        let line = app.staticTexts["practice.pickedUp"]
        XCTAssertTrue(line.appears(timeout: 10))
        XCTAssertEqual(line.label, "Picked up at 2 · 1 answered earlier")
        expectReadingColumn(line)
        attachLooks(app, "iPad set progress, the line")

        app.buttons["practice.startOver"].tap()
        XCTAssertTrue(app.staticTexts["practice.startOverSheet.title"].appears(timeout: 5))
        attach(app, "iPad set progress, Start over asks once")
        app.buttons["practice.startOverSheet.confirm"].tap()
        XCTAssertTrue(line.disappears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 8"), app.staticTexts["practice.count"].label)
    }

    /// Deleting the course open beside the list closes it, and Recently deleted opens beside the
    /// list and brings it back.
    @MainActor
    func testDeletingTheOpenCourseClosesItAndRecentlyDeletedOpensBeside() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let fundamentals = app.buttons["home.course.NURS 220"]
        XCTAssertTrue(fundamentals.appears(timeout: 5))
        fundamentals.tap()
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 5))

        fundamentals.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "home.hold.delete", "Delete"))
        let title = app.staticTexts["deleteSheet.title"]
        XCTAssertTrue(title.appears(timeout: 5))
        waitForLabel(title, containing: "Delete NURS 220 and its 146 questions?")
        attach(app, "iPad course delete, asked once")
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(fundamentals.disappears(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["home.noCourse"].appears(timeout: 5), "its screen beside the list goes")

        let recentlyDeleted = app.buttons["home.recentlyDeleted"]
        reveal(recentlyDeleted, in: app)
        recentlyDeleted.tap()
        XCTAssertTrue(app.navigationBars["Recently deleted"].appears(timeout: 5))
        let bringBack = app.buttons["deleted.bringBack.NURS 220"]
        XCTAssertTrue(bringBack.appears(timeout: 5))
        XCTAssertLessThan(recentlyDeleted.frame.maxX, bringBack.frame.minX, "beside the list")
        attachLooks(app, "iPad recently deleted")
        bringBack.tap()
        XCTAssertTrue(app.staticTexts["NURS 220 is back."].appears(timeout: 5))
        XCTAssertTrue(fundamentals.appears(timeout: 5), "back in the list")
    }

    @MainActor
    func testPracticeKeepsTheListCurrent() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let mentalHealth = app.buttons["home.course.NURS 310"]
        XCTAssertTrue(mentalHealth.appears(timeout: 5))
        let answered = try XCTUnwrap(mentalHealth.value as? String)

        openFolder(app, "Weeks 1-3")
        tapVisible(app.buttons["course.set.Mixed Clinical Judgment"], in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 10))
        expectReadingColumn(app.staticTexts["practice.stem"])
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 5))
        app.buttons["practice.close"].tap()

        // The answer counts in the course's card in the list, which stayed on screen.
        let changed = NSPredicate(format: "value != %@", answered)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: mentalHealth)], timeout: 10), .completed, "still \(answered)")
    }

    /// The frozen view beside its sidebar: the line stays in the status bar, and the sidebar's + and
    /// the course's both answer with the note.
    @MainActor
    func testTheFrozenViewAnswersBesideTheSidebar() throws {
        let app = launch("owner")
        let course = app.buttons["home.course.NURS 310"]
        XCTAssertTrue(course.appears(timeout: 10))
        XCTAssertEqual(app.staticTexts["frozen.line"].label, "Frozen view of sam@example.com")
        course.tap()
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5))
        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        let note = app.staticTexts["frozen.note"]
        XCTAssertTrue(note.appears(timeout: 5))
        XCTAssertEqual(note.label, "This is a frozen view of sam@example.com. Nothing here can be changed.")
        attach(app, "frozen view on iPad")
        note.tap()
        XCTAssertTrue(note.disappears(timeout: 5))
        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        XCTAssertTrue(note.appears(timeout: 5))
    }

    @MainActor
    func testSignInIsAColumnInTheMiddle() throws {
        let app = launch("signed-out")
        let title = app.staticTexts["signIn.title"]
        XCTAssertTrue(title.appears(timeout: 10))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let field = app.textFields["signIn.email"]
            XCTAssertTrue(field.appears(timeout: 5))
            // Measured once the turn has settled: just after it, the column can still be moving.
            let centered = NSPredicate { _, _ in abs(field.frame.midX - app.windows.firstMatch.frame.midX) <= 1 }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: centered, evaluatedWith: field)], timeout: 5), .completed, "\(field.frame.midX) is not the middle")
            XCTAssertLessThanOrEqual(field.frame.width, 480)
            attach(app, "ipad sign in, \(orientation == .portrait ? "portrait" : "landscape")")
        }
    }

    /// Every screen, in both orientations and both looks, for a look by eye in the test results.
    @MainActor
    func testScreensInBothOrientationsLightAndDark() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let mentalHealth = app.buttons["home.course.NURS 310"]
        for look in ["Light", "Dark"] {
            openTab(app, "Settings")
            let choice = app.buttons[look]
            reveal(choice, in: app)
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                let tag = "\(look.lowercased()), \(orientation == .portrait ? "portrait" : "landscape")"
                openTab(app, "Settings")
                app.swipeDown()
                attach(app, "ipad settings, \(tag)")
                tapVisible(app.buttons["settings.changePassword"], in: app)
                XCTAssertTrue(app.secureTextFields["changePassword.current"].appears(timeout: 5))
                attach(app, "ipad change password, \(tag)")
                goBack(app, from: "Change password")
                tapVisible(app.buttons["settings.semester.1"], in: app)
                XCTAssertTrue(app.textFields["semester.name"].appears(timeout: 5))
                attach(app, "ipad semester, \(tag)")
                goBack(app, from: "Semester 1")
                XCTAssertTrue(app.buttons["settings.changePassword"].appears(timeout: 5))
                tapVisible(app.buttons["settings.connectAgent"], in: app)
                expectReadingColumn(app.buttons["connectAgent.continue"])
                attach(app, "ipad connect an agent, \(tag)")
                goBack(app, from: "Connect an agent")
                XCTAssertTrue(app.buttons["settings.changePassword"].appears(timeout: 5))

                openTab(app, "Add")
                XCTAssertTrue(app.buttons["add.import"].appears(timeout: 5))
                attach(app, "ipad add, \(tag)")
                app.buttons["add.import"].tap()
                XCTAssertTrue(app.buttons["import.check"].appears(timeout: 5))
                expectReadingColumn(app.buttons["import.check"])
                attach(app, "ipad import, \(tag)")
                goBack(app, from: "Import")
                XCTAssertTrue(app.buttons["add.import"].appears(timeout: 5))

                openTab(app, "Home")
                mentalHealth.tap()
                XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))
                attach(app, "ipad course, \(tag)")

                app.buttons["course.add"].tap()
                chooseFromMenu(menuItem(app, "course.add.page", "New page"))
                let cancel = app.buttons["editPage.cancel"]
                XCTAssertTrue(cancel.appears(timeout: 5))
                attach(app, "ipad new exam page sheet, \(tag)")
                tapWhenStill(cancel)
                XCTAssertTrue(cancel.disappears(timeout: 5))

                for tile in ["review", "terms", "exam"] {
                    app.buttons["course.tile.\(tile)"].tap()
                    XCTAssertTrue(app.buttons["course.tile.\(tile)"].disappears(timeout: 5))
                    attach(app, "ipad \(tile), \(tag)")
                    if tile == "review" {
                        tapVisible(app.buttons["review.clear"], in: app)
                        XCTAssertTrue(app.staticTexts["review.clearSheet.title"].appears(timeout: 5))
                        attach(app, "ipad confirm sheet, \(tag)")
                        tapWhenStill(app.buttons["review.clearSheet.cancel"])
                        XCTAssertTrue(app.staticTexts["review.clearSheet.title"].disappears(timeout: 5))
                    }
                    mentalHealth.tap()
                    XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))
                }

                open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
                XCTAssertTrue(app.buttons["page.more"].appears(timeout: 5))
                attach(app, "ipad page, \(tag)")
                openFolder(app, "Week 2")
                XCTAssertTrue(app.buttons["folder.more"].appears(timeout: 5))
                attach(app, "ipad folder, \(tag)")
                mentalHealth.tap()
                XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))

                openFolder(app, "Weeks 1-3")
                tapVisible(app.buttons["course.set.Mixed Clinical Judgment"], in: app)
                XCTAssertTrue(app.staticTexts["practice.stem"].appears(timeout: 10))
                // The set opens past the answer of the pass before, so each pass begins it again.
                if app.buttons["practice.startOver"].exists {
                    attach(app, "ipad practice picked up, \(tag)")
                    app.buttons["practice.startOver"].tap()
                    XCTAssertTrue(app.staticTexts["practice.startOverSheet.title"].appears(timeout: 5))
                    attach(app, "ipad start over, \(tag)")
                    tapWhenStill(app.buttons["practice.startOverSheet.confirm"])
                    XCTAssertTrue(app.buttons["practice.startOver"].disappears(timeout: 5))
                }
                attach(app, "ipad practice, \(tag)")
                tapVisible(app.buttons["practice.option.0"], in: app)
                app.buttons["practice.check"].tap()
                XCTAssertTrue(app.buttons["practice.next"].appears(timeout: 5))
                attach(app, "ipad practice feedback, \(tag)")
                app.buttons["practice.close"].tap()
                XCTAssertTrue(app.buttons["practice.close"].disappears(timeout: 5))
            }
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// The element sits in a column no wider than the reading width.
    @MainActor
    private func expectReadingColumn(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.appears(timeout: 5), file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.width, Self.contentMax, "\(element) is \(element.frame.width) wide", file: file, line: line)
    }
}
