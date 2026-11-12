import XCTest

/// The owner's frozen view of a user account, end to end against the in-process fake server with
/// invented accounts only: every screen laid out as the user's, and each control answering with the
/// note instead of opening a sheet or sending a write.
final class FrozenViewUITests: XCTestCase {
    private let noteText = "This is a frozen view of sam@example.com. Nothing here can be changed."

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    /// The same walk as the user and as the owner: everything both can see sits in the same place.
    @MainActor
    func testEveryScreenIsLaidOutAsTheUsersIs() throws {
        let user = walk(launch("exam-in-progress"), named: "user")
        let frozen = walk(launch("owner-exam-in-progress"), named: "frozen")
        XCTAssertEqual(Set(user.keys), Set(frozen.keys))
        for (element, frame) in user {
            // Toolbar items settle within a hundredth of a point of where they were; one point is a move.
            guard let other = frozen[element] else { continue }
            for (a, b) in [(frame.minX, other.minX), (frame.minY, other.minY), (frame.width, other.width), (frame.height, other.height)] {
                XCTAssertEqual(a, b, accuracy: 1, "\(element) moved")
            }
        }
    }

    @MainActor
    func testHomeAndCourseAnswerWithTheNote() throws {
        let app = launch("owner")
        XCTAssertTrue(app.buttons["home.course.NURS 310"].appears(timeout: 10))
        XCTAssertEqual(app.staticTexts["frozen.line"].label, "Frozen view of sam@example.com")

        app.buttons["home.add"].tap()
        chooseFromMenu(menuItem(app, "home.add.topic", "New study topic"))
        expectNote(app, "Home's +")
        app.buttons["home.course.NURS 310"].press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "home.hold.delete", "Delete"))
        expectNote(app, "a held card's Delete")

        open(app.buttons["home.course.NURS 310"], titled: "NURS 310", in: app)
        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        expectNote(app, "the course's +")
        app.buttons["course.more"].tap()
        chooseFromMenu(menuItem(app, "course.rename", "Rename"))
        expectNote(app, "the course's Rename")
    }

    @MainActor
    func testExamPageFolderAndPracticeAnswerWithTheNote() throws {
        let app = launch("owner")
        XCTAssertTrue(app.buttons["home.course.NURS 310"].appears(timeout: 10))
        open(app.buttons["home.course.NURS 310"], titled: "NURS 310", in: app)
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        XCTAssertTrue(app.buttons["page.startExam"].exists)

        tapVisible(app.buttons["page.edit"], in: app)
        expectNote(app, "Study material's Edit")
        app.buttons["page.more"].tap()
        chooseFromMenu(menuItem(app, "page.more.editPage", "Edit page"))
        expectNote(app, "Edit page")
        app.buttons["page.add"].tap()
        chooseFromMenu(menuItem(app, "page.add.folder", "New folder on this page"))
        expectNote(app, "the page's +")

        open(app.buttons["folder.Week 1"], titled: "Week 1", in: app)
        app.buttons["folder.add"].tap()
        expectNote(app, "Import here")
        app.buttons["folder.more"].tap()
        chooseFromMenu(menuItem(app, "folder.more.delete", "Delete folder"))
        expectNote(app, "Delete folder")
        app.buttons["folder.select"].tap()
        expectNote(app, "Select")
        XCTAssertFalse(app.buttons["folder.pick.Rights, Law, and Ethics"].exists)

        // A set opens where she left it, and the runner answers with the note.
        let set = app.buttons["course.set.Rights, Law, and Ethics"]
        set.press(forDuration: 1.2)
        chooseFromMenu(menuItem(app, "delete.Rights, Law, and Ethics", "Delete"))
        expectNote(app, "a held set's Delete")
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        expectNote(app, "the runner opening")
        XCTAssertTrue(app.staticTexts["practice.stem"].exists, "she reads the question")
        let option = app.buttons["practice.option.0"]
        tapVisible(option, in: app)
        expectNote(app, "a choice")
        XCTAssertFalse(option.isSelected)
        app.buttons["practice.check"].tap()
        expectNote(app, "Check answer")
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.buttons["practice.close"].disappears(timeout: 5))
    }

    @MainActor
    func testReviewExamSetupAndExamAnswerWithTheNote() throws {
        let app = launch("owner-exam-in-progress")
        XCTAssertTrue(app.buttons["home.course.NURS 310"].appears(timeout: 10))
        open(app.buttons["home.course.NURS 310"], titled: "NURS 310", in: app)

        open(app.buttons["course.tile.review"], titled: "Review", in: app)
        tapVisible(app.buttons["review.clear"], in: app)
        expectNote(app, "Clear the review list")
        XCTAssertFalse(app.buttons["review.clearSheet.confirm"].exists)
        goBack(app, from: "Review")

        open(app.buttons["course.tile.exam"], titled: "Exam", in: app)
        app.switches["exam.wrongOnly"].tap()
        expectNote(app, "Wrong questions only")
        tapVisible(app.buttons["exam.folder.Week 1"], in: app)
        expectNote(app, "a folder's tick")
        tapVisible(app.buttons["exam.start"], in: app)
        expectNote(app, "Start exam")

        // Her running exam opens as she left it, and nothing in it answers.
        tapVisible(app.buttons["exam.resume"], in: app)
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 5))
        expectNote(app, "the exam opening")
        tapVisible(app.buttons["practice.option.0"], in: app)
        expectNote(app, "an exam choice")
        app.buttons["exam.submit"].tap()
        expectNote(app, "Submit")
        app.buttons["exam.skip"].tap()
        expectNote(app, "Skip")

        // Only End exam leaves a running exam: here it leaves, with the note, and ends nothing.
        app.buttons["exam.end"].tap()
        XCTAssertTrue(app.buttons["exam.end"].disappears(timeout: 5))
        expectNote(app, "End exam")
        XCTAssertTrue(app.buttons["exam.resume"].exists, "the exam still runs")
    }

    @MainActor
    func testTheAddTabOpensAndAnswersWithTheNote() throws {
        let app = launch("owner")
        XCTAssertTrue(app.buttons["home.course.NURS 310"].appears(timeout: 10))
        openTab(app, "Add")
        XCTAssertTrue(app.staticTexts[noteText].appears(timeout: 5), "said where the server would say why she cannot make questions")
        XCTAssertFalse(app.buttons["add.make"].exists)
        app.buttons["add.import"].tap()
        XCTAssertTrue(app.buttons["import.file"].appears(timeout: 5))
        app.buttons["import.file"].tap()
        expectNote(app, "Choose a file")
        app.buttons["import.check"].tap()
        expectNote(app, "Check file")
    }

    /// The note shows, in its words, and goes when tapped, so the next control's is its own.
    @MainActor
    private func expectNote(_ app: XCUIApplication, _ control: String, file: StaticString = #filePath, line: UInt = #line) {
        let note = app.staticTexts["frozen.note"]
        XCTAssertTrue(note.appears(timeout: 5), "\(control) showed no note", file: file, line: line)
        XCTAssertEqual(note.label, noteText, file: file, line: line)
        note.tap()
        XCTAssertTrue(note.disappears(timeout: 5), "the note stayed after \(control)", file: file, line: line)
    }

    /// The frame once it holds still: a toolbar item can still be gliding into place just after a push.
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var last = element.frame
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let now = element.frame
            if now == last { return now }
            last = now
        }
        return last
    }

    /// Walks the screens the frozen view shares with the user's, keeping each screen's picture and
    /// where its controls sit.
    @MainActor
    private func walk(_ app: XCUIApplication, named name: String) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        func keep(_ screen: String, _ identifiers: [String]) {
            // The note a runner opens with, out of the way of the comparison.
            let note = app.staticTexts["frozen.note"]
            if note.exists {
                note.tap()
                XCTAssertTrue(note.disappears(timeout: 5))
            }
            for identifier in identifiers {
                let element = app.descendants(matching: .any)[identifier].firstMatch
                XCTAssertTrue(element.appears(timeout: 5), "\(name): no \(identifier) on \(screen)")
                frames["\(screen) \(identifier)"] = settledFrame(of: element)
            }
            attach(app, "\(name) \(screen)")
        }

        // The user lands on the course she used last, and the owner on Home.
        let course = app.navigationBars["NURS 310"]
        if course.appears(timeout: 2) {
            goBack(app, from: "NURS 310")
        }
        XCTAssertTrue(app.buttons["home.course.NURS 310"].appears(timeout: 10))
        keep("Home", ["home.add", "home.course.NURS 310", "home.course.NURS 220"])

        open(app.buttons["home.course.NURS 310"], titled: "NURS 310", in: app)
        keep("Course", ["course.add", "course.more", "course.summary", "course.tile.exam", "course.tile.review", "course.tile.terms", "course.page.Exam 1"])

        open(app.buttons["course.tile.review"], titled: "Review", in: app)
        keep("Review", ["review.filters", "review.practice", "review.question.communication-v1-q6"])
        goBack(app, from: "Review")

        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        keep("Exam page", ["page.add", "page.more", "page.note", "page.startExam", "page.edit", "folder.Week 1", "folder.Week 2"])

        open(app.buttons["folder.Week 1"], titled: "Week 1", in: app)
        keep("Folder", ["folder.add", "folder.more", "folder.note", "folder.select", "course.set.Rights, Law, and Ethics"])

        tapVisible(app.buttons["course.set.Rights, Law, and Ethics"], in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        // Not its choices: each opening shuffles them.
        keep("Practice", ["practice.close", "practice.count", "practice.stem", "practice.check"])
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.buttons["practice.close"].disappears(timeout: 5))

        openTab(app, "Add")
        keep("Add", ["add.import"])

        // Her running exam last: nothing else in the walk changes what the screens show.
        openTab(app, "Home")
        goBack(app, from: "Week 1")
        goBack(app, from: "Exam 1")
        open(app.buttons["course.tile.exam"], titled: "Exam", in: app)
        keep("Running exam's setup", ["exam.resume", "exam.wrongOnly"])
        tapVisible(app.buttons["exam.resume"], in: app)
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 5))
        keep("Exam", ["exam.end", "practice.count", "exam.skip", "exam.submit"])
        app.terminate()
        return frames
    }
}
