import XCTest

/// Study topics end to end against the in-process fake server of the Debug launch seam: made from
/// Home's +, filled by Import, given a study page with its primer, examined, and renamed and
/// archived by holding it on Home. Invented topics and question files only.
final class TopicsUITests: XCTestCase {
    private let topic = "Invented Systems Design"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testATopicFromHomeToAnExamOverItsStudyPage() throws {
        try skipOnIPad()
        let app = launch("signed-in")

        // Her course reads as it always did.
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pages"].appears(timeout: 5))
        goBack(app, from: "NURS 310")

        // Home: Study topics, empty, and the +'s New study topic.
        reveal(app.staticTexts["A topic is a place for questions that are not a course: a certification, a language, your own notes."], in: app)
        attachLooks(app, "T-1 home, no topics")
        app.buttons["home.add"].tap()
        chooseFromMenu(app.buttons["home.add.topic"])
        let name = app.textFields["newTopic.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["A topic has folders and pages, like a course, without a semester."].exists)
        name.typeText(topic)
        attachLooks(app, "T-2 new topic")
        tapWhenStill(app.buttons["newTopic.save"])

        // Done opens it, called by its name, worded as a topic.
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["course.summary"].label, "0 questions · 0 folders")
        XCTAssertTrue(app.staticTexts["This topic has no question sets yet."].exists)
        attachLooks(app, "T-3 topic, new")

        // Import files a set into it, from the Study topics group.
        openTab(app, "Add")
        XCTAssertTrue(app.navigationBars["Add questions"].appears(timeout: 5))
        app.buttons["add.import"].tap()
        XCTAssertTrue(app.navigationBars["Import"].appears(timeout: 5))
        waitForLabel(app.buttons["import.course"], containing: topic)
        paste(AddUITests.file, in: app)
        tapVisible(app.buttons["import.check"], in: app)
        XCTAssertTrue(app.buttons["import.commit"].appears(timeout: 5))
        tapVisible(app.buttons["import.commit"], in: app)
        XCTAssertTrue(app.staticTexts["import.done.title"].appears(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["import.done.copy"].label,
            "“Invented Sleep and Rest” · 3 questions in \(topic), Unsorted. It is in the topic’s Folders list until you move it."
        )
        app.buttons["import.done.open"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        goBack(app, from: "Unsorted")

        // The +'s New page makes Page 1 with the topic's folder and its primer link.
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pages"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["No pages yet. Tap + to make Page 1."].exists)
        XCTAssertTrue(app.staticTexts["Folders on no page. Open one to see its sets."].exists)
        attachLooks(app, "T-4 topic, a folder")
        app.buttons["course.add"].tap()
        XCTAssertTrue(app.staticTexts["Add to \(topic)"].appears(timeout: 5))
        XCTAssertEqual(app.buttons["course.add.page"].label, "New page")
        chooseFromMenu(app.buttons["course.add.page"])
        XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
        XCTAssertEqual(app.textFields["editPage.name"].value as? String, "Page 1")
        app.buttons["editPage.chip.free.Unsorted"].tap()
        XCTAssertEqual(app.staticTexts["editPage.line"].label, "1 folder · 3 questions")
        let link = app.textFields["editPage.link"]
        tapVisible(link, in: app)
        link.typeText("notes.example.com/stage-1")
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.staticTexts["A link has to be a web address, such as https://example.com/primer."].appears(timeout: 5))
        link.clearText()
        link.typeText("https://notes.example.com/stage-1")
        attachLooks(app, "T-5 new page")
        app.buttons["editPage.save"].tap()

        // The page opens with its primer above Start exam.
        XCTAssertTrue(app.navigationBars["Page 1"].appears(timeout: 10))
        let primer = app.buttons["page.primer"]
        XCTAssertTrue(primer.appears(timeout: 5))
        XCTAssertTrue(primer.label.contains("Open the primer"), primer.label)
        XCTAssertTrue(primer.label.contains("notes.example.com"), primer.label)
        XCTAssertTrue(app.staticTexts["Exams you finish over Page 1 show up here with their scores."].exists)
        attachLooks(app, "T-6 page")

        // An exam over it runs as in a course, and goes back to the topic.
        app.buttons["page.startExam"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts[topic].exists, "the topic's name alone, with no code")
        XCTAssertTrue(app.staticTexts["Page 1"].exists, "the folders by page")
        reveal(app.buttons["exam.start"], in: app)
        let count = app.descendants(matching: .any)["exam.summary.count"]
        waitForLabel(count, containing: "3 questions, in 4.5 minutes")
        XCTAssertEqual(count.label, "3 questions, in 4.5 minutes")
        attachLooks(app, "T-7 exam setup")
        app.buttons["exam.start"].tap()
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10))
        app.buttons["exam.end"].tap()
        XCTAssertTrue(app.buttons["exam.endSheet.confirm"].appears(timeout: 5))
        app.buttons["exam.endSheet.confirm"].tap()
        XCTAssertTrue(app.staticTexts["examResult.title"].appears(timeout: 10))
        let back = app.buttons["examResult.back"]
        XCTAssertEqual(back.label, "Back to topic")
        back.tap()
        // Back to the screen the exam started from, as in a course: the page, which now
        // lists the exam, then the topic, which lists the page.
        XCTAssertTrue(app.navigationBars["Page 1"].appears(timeout: 10))
        let sitting = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "page.sitting.")).firstMatch
        XCTAssertTrue(sitting.appears(timeout: 5))
        attachLooks(app, "T-8 page, a past exam")
        goBack(app, from: "Page 1")
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        XCTAssertTrue(app.buttons["course.page.Page 1"].appears(timeout: 5))
    }

    @MainActor
    func testHoldingATopicOnHomeRenamesMovesAndArchivesIt() throws {
        try skipOnIPad()
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        goBack(app, from: "NURS 310")

        // Two topics, made from the +.
        for name in ["Invented Spanish Verbs", topic] {
            app.buttons["home.add"].tap()
            chooseFromMenu(app.buttons["home.add.topic"])
            let field = app.textFields["newTopic.name"]
            XCTAssertTrue(field.appears(timeout: 5))
            field.typeText(name)
            tapWhenStill(app.buttons["newTopic.save"])
            XCTAssertTrue(app.navigationBars[name].appears(timeout: 10), name)
            goBack(app, from: name)
        }
        let card = app.buttons["home.topic.\(topic)"]
        reveal(card, in: app)

        // A topic's menu has no Move: it has no semester.
        card.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["home.hold.rename"].appears(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.hold.move.")).firstMatch.exists)
        attachLooks(app, "T-9 home, holding a topic")
        chooseFromMenu(app.buttons["home.hold.rename"])
        XCTAssertTrue(app.navigationBars["Rename topic"].appears(timeout: 5))
        let name = app.textFields["renameCourse.title"]
        XCTAssertEqual(name.value as? String, topic)
        name.clearText()
        name.typeText("Invented Distributed Systems")
        app.buttons["renameCourse.save"].tap()
        let renamed = app.buttons["home.topic.Invented Distributed Systems"]
        XCTAssertTrue(renamed.appears(timeout: 10))
        XCTAssertFalse(card.exists)

        // The last topic moves up, above the other.
        let studied = app.buttons["home.topic.Invented Spanish Verbs"]
        reveal(renamed, in: app)
        XCTAssertGreaterThan(renamed.frame.minY, studied.frame.minY)
        renamed.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["home.hold.up"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["home.hold.down"].exists, "the last one has no Move down")
        chooseFromMenu(app.buttons["home.hold.up"])
        let above = NSPredicate { _, _ in renamed.frame.minY < studied.frame.minY }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: above, evaluatedWith: renamed)], timeout: 10), .completed, "it went above the other")

        // Archive: Home lists the other under Study topics, and this one under Archived, closed.
        reveal(renamed, in: app)
        renamed.press(forDuration: 1.2)
        chooseFromMenu(app.buttons["home.hold.archive"])
        XCTAssertTrue(renamed.disappears(timeout: 10))
        reveal(studied, in: app)
        let archived = app.buttons["home.archived"]
        tapVisible(archived, in: app)
        XCTAssertEqual(archived.value as? String, "Open")
        reveal(renamed, in: app)
        XCTAssertTrue(app.staticTexts["Study topics"].exists)
        attachLooks(app, "T-12 home, archived")
    }
}
