import XCTest

/// Review, Terms, an exam over her wrong questions, and the course page's exam pages and folders
/// with her edits, end to end against the in-process fake server of the Debug launch seam, which
/// keeps the server's rules and words. Invented questions and accounts only.
final class StudyUITests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    // MARK: Review (1c-1)

    @MainActor
    func testReviewFiltersPracticesAndClears() throws {
        let app = launch("signed-in")
        openTile(app, "review", title: "Review")
        XCTAssertTrue(app.staticTexts["NURS 310 · what you missed or guessed"].exists)
        for label in ["All 12", "Missed 6", "Partly 3", "Guessed 4"] {
            XCTAssertTrue(app.buttons[label].exists, label)
        }
        XCTAssertTrue(app.buttons["All 12"].isSelected)
        XCTAssertTrue(app.buttons["Practice these 12 (shuffled)"].exists)
        let first = app.buttons["review.question.communication-v1-q6"]
        XCTAssertTrue(first.label.contains("Missed, guessed"), first.label)
        XCTAssertTrue(app.buttons["review.question.communication-v1-q3"].label.contains("Partly right"))
        XCTAssertTrue(app.buttons["review.question.communication-v1-q8"].label.contains("Guessed"))
        attach(app, "1c-1 review")

        app.buttons["Missed 6"].tap()
        XCTAssertTrue(app.buttons["Practice these 6 (shuffled)"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["review.question.communication-v1-q3"].exists, "partly right is not missed")
        attach(app, "1c-1 review, missed")

        // One question, answered fully right without guessing, leaves the list.
        tapVisible(app.buttons["review.question.rights-v1-q0"], in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 1"))
        tapVisible(app.buttons["practice.option.0"], in: app)
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
        app.buttons["practice.next"].tap()
        XCTAssertTrue(app.staticTexts["result.title"].appears(timeout: 5))
        XCTAssertTrue(hasText(app, "Review finished · Review question"))
        app.buttons["result.done"].tap()
        XCTAssertTrue(app.buttons["Missed 5"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["review.question.rights-v1-q0"].exists)

        // The filtered list in the runner.
        tapVisible(app.buttons["Practice these 5 (shuffled)"], in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 5"), app.staticTexts["practice.count"].label)
        app.buttons["practice.close"].tap()

        // Clear asks first, in the web's words.
        app.buttons["All 11"].tap()
        tapVisible(app.buttons["review.clear"], in: app)
        XCTAssertTrue(app.staticTexts["review.clearSheet.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["review.clearSheet.title"].label, "Clear all 11 questions from this course's Review list?")
        XCTAssertTrue(app.staticTexts["Your answers and scores are kept. Only the list is emptied."].exists)
        attach(app, "1c-1 clear asks first")
        app.buttons["review.clearSheet.confirm"].tap()
        XCTAssertTrue(
            app.staticTexts["Questions you miss or flag as a guess show up here. They leave when you answer them fully right without guessing."]
                .appears(timeout: 5)
        )
        XCTAssertFalse(app.buttons["review.clear"].exists)
        attach(app, "1c-1 review, cleared")

        goBack(app, from: "Review")
        let tile = app.buttons["course.tile.review"]
        XCTAssertTrue(tile.appears(timeout: 5))
        let emptied = NSPredicate(format: "label BEGINSWITH %@", "0")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: emptied, evaluatedWith: tile)], timeout: 5), .completed, tile.label)
    }

    // MARK: Terms (1c-2)

    @MainActor
    func testTermsAreSearchable() throws {
        let app = launch("signed-in")
        openTile(app, "terms", title: "Terms")
        XCTAssertTrue(app.staticTexts["When a term is defined in more than one set, the newest set’s definition is the one shown here."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["terms.term.Advocacy"].appears(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["terms.term.Autonomy"].label.contains("Week 1 · Rights, Law, and Ethics"))
        attach(app, "1c-2 terms")

        let search = app.searchFields["Search terms"]
        XCTAssertTrue(search.appears(timeout: 5))
        search.tap()
        search.typeText("choices")
        XCTAssertTrue(app.descendants(matching: .any)["terms.term.Autonomy"].appears(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["terms.term.Advocacy"].exists)
        attach(app, "1c-2 terms, search")

        search.typeText(" zebra")
        XCTAssertTrue(app.staticTexts["No term matches “choices zebra”."].appears(timeout: 5))
    }

    // MARK: Exams (1c-3 to 1c-6)

    @MainActor
    func testWrongQuestionsExamFromSetupToResult() throws {
        let app = launch("signed-in")
        openTile(app, "exam", title: "Exam")
        XCTAssertTrue(app.staticTexts["NURS 310 · Mental Health"].exists)
        let week1 = app.buttons["exam.folder.Week 1"]
        let week2 = app.buttons["exam.folder.Week 2"]
        let week3 = app.buttons["exam.folder.Week 3"]
        XCTAssertTrue(week1.appears(timeout: 5))
        XCTAssertTrue(week1.label.contains("17 questions · exam bank"), week1.label)
        XCTAssertTrue(week2.label.contains("26 questions"), week2.label)
        XCTAssertTrue(app.staticTexts["Tick at least one folder."].exists)
        XCTAssertTrue(app.staticTexts["Exam 1"].exists, "the folders by page")
        XCTAssertTrue(app.staticTexts["On no page"].exists)
        XCTAssertFalse(app.buttons["exam.start"].isEnabled)
        attach(app, "1c-3 exam setup")

        flip(app.switches["exam.wrongOnly"])
        XCTAssertTrue(week1.label.contains("4 wrong of 17 · exam bank"), week1.label)
        XCTAssertTrue(week3.label.contains("0 wrong of 31 · exam bank"), week3.label)
        XCTAssertFalse(week3.isEnabled, "a folder with nothing wrong cannot be ticked")
        week1.tap()
        week2.tap()
        XCTAssertTrue(week1.isSelected)
        // The plan is the server's, read again after each tick.
        waitForLabel(week1, containing: "4 in exam")
        waitForLabel(week2, containing: "7 in exam")
        let count = app.descendants(matching: .any)["exam.summary.count"]
        reveal(app.buttons["exam.start"], in: app)
        waitForLabel(count, containing: "11 questions, in 16.5 minutes")
        XCTAssertEqual(count.label, "11 questions, in 16.5 minutes")
        XCTAssertEqual(
            app.staticTexts["exam.summary.split"].label,
            "4 from Week 1 · 7 from Week 2 · Fewer than 40, so it’s all of them at 1.5 minutes each."
        )
        XCTAssertEqual(app.staticTexts["exam.summary.fallback"].label, "Week 2 has no exam bank yet, so it uses its practice questions.")
        attach(app, "1c-3 exam setup, wrong questions only")

        app.buttons["exam.start"].tap()
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10))
        expectCount(app, "1 of 11")
        XCTAssertTrue(app.staticTexts["practice.count"].label.contains("Exam · Weeks 1-2"))
        XCTAssertTrue(app.descendants(matching: .any)["exam.timer"].exists)
        XCTAssertFalse(app.buttons["exam.submit"].isEnabled, "nothing picked yet")
        attach(app, "1c-4 exam")

        // 1 single, right. 2 priority, skipped. 3 select all, partly right. 4 highlight, skipped.
        // 5 single from practice, wrong. 6 to 11 skipped.
        tapVisible(app.buttons["practice.option.0"], in: app)
        attach(app, "1c-4 exam, picked")
        submit(app, next: "2 of 11")
        app.buttons["exam.skip"].tap()
        expectCount(app, "3 of 11")
        tapVisible(app.buttons["practice.option.0"], in: app)
        submit(app, next: "4 of 11")
        app.buttons["exam.skip"].tap()
        expectCount(app, "5 of 11")
        tapVisible(app.buttons["practice.option.1"], in: app)
        submit(app, next: "6 of 11")
        for position in 6...11 {
            app.buttons["exam.skip"].tap()
            if position < 11 { expectCount(app, "\(position + 1) of 11") }
        }
        expectCount(app, "2 of 11")
        let notice = app.descendants(matching: .any)["exam.skippedNotice"]
        XCTAssertTrue(notice.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["8 skipped questions left. This is the first one."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["practice.meta"].label.contains("Skipped earlier"))
        attach(app, "1c-4 exam, back to the skipped ones")

        app.buttons["exam.end"].tap()
        XCTAssertTrue(app.staticTexts["exam.endSheet.title"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["exam.endSheet.title"].label, "End the exam now?")
        XCTAssertTrue(app.staticTexts["The 3 questions you answered will be scored. Skipped and unreached questions score 0 and stay out of Review."].exists)
        attach(app, "1c-5 end the exam")
        app.buttons["exam.endSheet.cancel"].tap()
        XCTAssertTrue(app.staticTexts["exam.endSheet.title"].disappears(timeout: 5))
        expectCount(app, "2 of 11")

        app.buttons["exam.end"].tap()
        XCTAssertTrue(app.buttons["exam.endSheet.confirm"].appears(timeout: 5))
        app.buttons["exam.endSheet.confirm"].tap()
        let title = app.staticTexts["examResult.title"]
        XCTAssertTrue(title.appears(timeout: 10))
        XCTAssertEqual(title.label, "1 of 11 fully right")
        XCTAssertTrue(app.staticTexts["examResult.points"].label.hasSuffix(" · Ended early"), app.staticTexts["examResult.points"].label)
        XCTAssertTrue(hasText(app, "Exam result · Weeks 1-2 · Wrong questions only"))
        XCTAssertTrue(app.staticTexts["Week 2 had no exam bank, so its questions came from practice sets."].exists)
        for (label, value) in [("Partly right", "1"), ("Missed", "1"), ("Guessed", "0"), ("Not answered", "8")] {
            XCTAssertTrue(app.descendants(matching: .any)["examResult.stat.\(label)"].label.hasPrefix(value), label)
        }
        XCTAssertTrue(app.buttons["Open Review · 1 from this exam"].exists)
        XCTAssertEqual(
            app.staticTexts["examResult.bankWrong"].label,
            "1 exam-bank question you got wrong stays out of Review. Turn on Wrong questions only to take it again."
        )
        attach(app, "1c-6 exam result")
        app.swipeUp()
        XCTAssertTrue(hasText(app, "Week 1, exam bank, 1 of 4"))
        XCTAssertTrue(hasText(app, "Week 2, practice questions, 0 of 7"))
        attach(app, "1c-6 exam result, by folder and step")
        tapVisible(app.buttons["examResult.question.1"], in: app)
        XCTAssertEqual(app.buttons["examResult.question.1"].value as? String, "Expanded")
        attach(app, "1c-6 exam result, question opened")

        // Open Review goes to the course's Review list; Back returns to the setup.
        reveal(app.buttons["examResult.openReview"], in: app)
        app.buttons["examResult.openReview"].tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 10))
        XCTAssertTrue(app.buttons["review.question.communication-v1-q0"].appears(timeout: 5), "the practice question she missed")
        goBack(app, from: "Review")
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        reveal(app.staticTexts["Past exams"], in: app)
        attach(app, "1c-3 exam setup, after the exam")
    }

    @MainActor
    func testPastExamOpensItsResultAndTimeRunsOutOnTheServer() throws {
        let app = launch("signed-in")
        openTile(app, "exam", title: "Exam")
        let past = app.buttons["exam.past.e0000000-0000-4000-8000-000000000002"]
        reveal(past, in: app)
        XCTAssertTrue(past.label.contains("Time ran out"), past.label)
        past.tap()
        XCTAssertTrue(app.staticTexts["examResult.title"].appears(timeout: 10))
        XCTAssertTrue(app.staticTexts["examResult.points"].label.hasSuffix("· Time ran out"), app.staticTexts["examResult.points"].label)
        XCTAssertTrue(app.descendants(matching: .any)["examResult.stat.Not answered"].label.hasPrefix("2"))
        app.buttons["examResult.done"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
    }

    // MARK: The course page: exam pages and folders

    @MainActor
    func testCoursePageOpensExamPagesAndFolders() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let exam1 = app.buttons["course.page.Exam 1"]
        XCTAssertTrue(exam1.appears(timeout: 5))
        XCTAssertTrue(exam1.label.contains("2 folders · 43 questions"), exam1.label)
        XCTAssertTrue(exam1.label.contains("26 of 43"), exam1.label)
        let exam2 = app.buttons["course.page.Exam 2"]
        XCTAssertTrue(exam2.label.contains("1 folder · 31 questions"), exam2.label)
        XCTAssertTrue(exam2.label.contains("Not started"), exam2.label)
        let loose = app.buttons["folder.Weeks 1-3"]
        XCTAssertTrue(loose.label.contains("1 set · 8 questions"), loose.label)
        XCTAssertFalse(app.buttons["folder.Week 1"].exists, "a folder on a page is listed only there")
        XCTAssertTrue(app.staticTexts["Folders on no page. Open one to see its sets."].exists)
        attach(app, "C course page")

        // An exam page: Start exam, its folders, and the exams she took over them.
        exam1.tap()
        XCTAssertTrue(app.navigationBars["Exam 1"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["page.note"].label, "2 folders · 3 practice sets · 43 questions")
        let draw = app.staticTexts["page.draw"]
        XCTAssertTrue(draw.appears(timeout: 5), "the server's plan for the page")
        XCTAssertEqual(draw.label, "40 questions from the 43 in these 2 folders, or Wrong questions only.")
        XCTAssertTrue(app.staticTexts["Study material"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["page.twins"].label.contains("Exam twins: 17 in Week 1 · exams draw from these first")
        )
        XCTAssertTrue(app.buttons["folder.Week 1"].label.contains("1 set · 13 of 17 fully right"))
        XCTAssertTrue(app.buttons["folder.Week 2"].label.contains("2 sets · 9 of 26 answered"))
        attach(app, "C exam page")
        let sitting = app.buttons["page.sitting.e0000000-0000-4000-8000-000000000001"]
        reveal(sitting, in: app)
        XCTAssertTrue(app.buttons["page.sitting.e0000000-0000-4000-8000-000000000002"].exists)
        XCTAssertFalse(app.buttons["page.sitting.e0000000-0000-4000-8000-000000000003"].exists, "Weeks 1-3 spans both pages")
        XCTAssertTrue(app.staticTexts["Past exams"].exists)
        attach(app, "C exam page, past exams")
        sitting.tap()
        XCTAssertTrue(app.staticTexts["examResult.title"].appears(timeout: 10))
        app.buttons["examResult.done"].tap()
        XCTAssertTrue(app.navigationBars["Exam 1"].appears(timeout: 5))

        // A folder: which page it is on, its sets, and its exam line.
        app.swipeDown()
        open(app.buttons["folder.Week 2"], titled: "Week 2", in: app)
        XCTAssertEqual(app.staticTexts["folder.note"].label, "On Exam 1 · 2 sets · 9 of 26 answered")
        XCTAssertTrue(app.buttons["course.set.Therapeutic Communication and the Relationship"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["folder.bank"].label.contains("No exam bank yet · exams use practice questions"))
        attach(app, "C folder")
        goBack(app, from: "Week 2")
        goBack(app, from: "Exam 1")
        openFolder(app, "Week 3", on: "Exam 2")
        XCTAssertTrue(app.descendants(matching: .any)["folder.bank"].label.contains("Exam twins: 31 questions, exams only"))
        attach(app, "C folder, exam twins")

        // Start exam on an exam page opens the setup with its folders ticked.
        goBack(app, from: "Week 3")
        goBack(app, from: "Exam 2")
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        tapVisible(app.buttons["page.startExam"], in: app)
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["exam.preselected"].label, "Exam 1 · 2 folders ticked for you")
        XCTAssertTrue(app.buttons["exam.folder.Week 1"].isSelected)
        XCTAssertTrue(app.buttons["exam.folder.Week 2"].isSelected)
        XCTAssertFalse(app.buttons["exam.folder.Week 3"].isSelected)
        attach(app, "C exam setup from Exam 1")
        reveal(app.buttons["exam.start"], in: app)
        let pageCount = app.descendants(matching: .any)["exam.summary.count"]
        waitForLabel(pageCount, containing: "40 questions, in 60 minutes")
        XCTAssertEqual(pageCount.label, "40 questions, in 60 minutes")
        attach(app, "C exam setup from Exam 1, summary")

        // The exam she takes from here shows under the page's Past exams when she comes back.
        app.buttons["exam.start"].tap()
        XCTAssertTrue(app.buttons["exam.end"].appears(timeout: 10))
        app.buttons["exam.end"].tap()
        XCTAssertTrue(app.buttons["exam.endSheet.confirm"].appears(timeout: 5))
        app.buttons["exam.endSheet.confirm"].tap()
        XCTAssertTrue(app.staticTexts["examResult.title"].appears(timeout: 10))
        app.buttons["examResult.done"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        goBack(app, from: "Exam")
        XCTAssertTrue(app.navigationBars["Exam 1"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["page.sitting.e0000000-0000-4000-8000-000000000004"].appears(timeout: 10))
    }

    @MainActor
    func testRenameFolderPutItOnAPageMoveASetAndOrderFolders() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        XCTAssertEqual(app.staticTexts["folder.note"].label, "On no page · 1 set · 8 questions")

        // Rename, in More: only the name changes.
        let more = app.buttons["folder.more"]
        XCTAssertTrue(more.appears(timeout: 5))
        XCTAssertEqual(more.label, "More for Weeks 1-3")
        XCTAssertFalse(app.buttons["Rename"].isHittable, "Rename is not a button on the screen")
        attachLooks(app, "C folder")
        more.tap()
        let rename = app.buttons["folder.more.rename"]
        XCTAssertTrue(rename.appears(timeout: 5))
        XCTAssertEqual(rename.label, "Rename")
        attachLooks(app, "C folder, More")
        chooseFromMenu(rename)
        let name = app.textFields["renameFolder.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Only the name changes. Its sets, their progress, its page and your past exams stay with it."].exists)
        name.clearAndType("Mixed review")
        attach(app, "C rename folder")
        app.buttons["renameFolder.save"].tap()
        XCTAssertTrue(app.navigationBars["Mixed review"].appears(timeout: 5))

        // Exam page: the folder goes on Exam 2, with its sets and progress.
        app.buttons["folder.page"].tap()
        XCTAssertTrue(app.navigationBars["Page"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mixed review can be on one page. Its sets and progress stay in the folder."].exists)
        XCTAssertTrue(app.buttons["examPage.none"].isSelected)
        XCTAssertTrue(app.buttons["examPage.new"].label.contains("Page 3"))
        app.buttons["examPage.page.Exam 2"].tap()
        attach(app, "C exam page sheet")
        app.buttons["examPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Page"].disappears(timeout: 5))
        waitForLabel(app.staticTexts["folder.note"], containing: "On Exam 2 · 1 set · 8 questions")

        // Select, then Move: the set goes to Week 2 with its answers.
        app.buttons["folder.select"].tap()
        app.buttons["folder.pick.Mixed Clinical Judgment"].tap()
        XCTAssertTrue(app.buttons["folder.pick.Mixed Clinical Judgment"].isSelected)
        let move = app.buttons["folder.move"]
        XCTAssertTrue(move.appears(timeout: 5))
        XCTAssertEqual(move.label, "Move 1 set")
        attach(app, "C folder, select")
        move.tap()
        XCTAssertTrue(app.navigationBars["Move to"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Moving “Mixed Clinical Judgment” out of Mixed review."].exists)
        let here = app.buttons["moveSets.folder.Exam 2.Mixed review"]
        XCTAssertFalse(here.isEnabled, "the folder it is in cannot be picked")
        XCTAssertTrue(here.label.contains("Here now"), here.label)
        app.buttons["moveSets.folder.Exam 1.Week 2"].tap()
        attach(app, "C move to")
        app.buttons["moveSets.save"].tap()
        XCTAssertTrue(app.navigationBars["Move to"].disappears(timeout: 5))
        XCTAssertTrue(app.staticTexts["No sets yet. Move sets here from another folder."].appears(timeout: 5))
        XCTAssertFalse(app.buttons["folder.move"].exists)
        attach(app, "C folder, emptied")

        // On the course page, no folder is left on no exam page.
        goBack(app, from: "Mixed review")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5))
        waitForLabel(app.buttons["course.page.Exam 2"], containing: "2 folders · 31 questions")
        XCTAssertFalse(app.staticTexts["Folders on no page. Open one to see its sets."].exists)

        // A name its list already has is refused in the server's words.
        openFolder(app, "Week 2", on: "Exam 1")
        XCTAssertTrue(app.buttons["course.set.Mixed Clinical Judgment"].exists, "the moved set is here")
        app.buttons["folder.more"].tap()
        chooseFromMenu(app.buttons["folder.more.rename"])
        let renamed = app.textFields["renameFolder.name"]
        XCTAssertTrue(renamed.appears(timeout: 5))
        renamed.clearAndType("week 1")
        app.buttons["renameFolder.save"].tap()
        XCTAssertTrue(app.staticTexts["Exam 1 already has a folder named Week 1."].appears(timeout: 5))
        attach(app, "C rename folder, refused")
        app.buttons["renameFolder.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Week 2"].appears(timeout: 5))

        // Her order: Edit, then the arrows, then Done.
        goBack(app, from: "Week 2")
        XCTAssertTrue(app.navigationBars["Exam 1"].appears(timeout: 5))
        XCTAssertLessThan(app.buttons["folder.Week 1"].frame.minY, app.buttons["folder.Week 2"].frame.minY)
        tapVisible(app.buttons["page.edit"], in: app)
        let down = app.buttons["reorder.down.Week 1"]
        XCTAssertTrue(down.appears(timeout: 5))
        XCTAssertFalse(app.buttons["reorder.up.Week 1"].isEnabled)
        XCTAssertTrue(app.buttons["page.editPage"].exists)
        down.tap()
        XCTAssertFalse(app.buttons["reorder.down.Week 1"].isEnabled, "now last")
        attach(app, "C exam page, order")
        app.buttons["page.edit"].tap()
        let week1 = app.buttons["folder.Week 1"]
        XCTAssertTrue(week1.appears(timeout: 5))
        XCTAssertLessThan(app.buttons["folder.Week 2"].frame.minY, week1.frame.minY)

        // The order is saved in QBank: the page reads it back when she opens it again.
        goBack(app, from: "Exam 1")
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        XCTAssertTrue(app.buttons["folder.Week 1"].appears(timeout: 5))
        XCTAssertLessThan(app.buttons["folder.Week 2"].frame.minY, app.buttons["folder.Week 1"].frame.minY)

        // An order she changed is saved before the page's editor opens, even when she cancels it.
        tapVisible(app.buttons["page.edit"], in: app)
        let up = app.buttons["reorder.up.Week 1"]
        XCTAssertTrue(up.appears(timeout: 5))
        up.tap()
        app.buttons["page.editPage"].tap()
        XCTAssertTrue(app.navigationBars["Edit Exam 1"].appears(timeout: 10))
        app.buttons["editPage.cancel"].tap()
        XCTAssertTrue(app.navigationBars["Edit Exam 1"].disappears(timeout: 5))
        goBack(app, from: "Exam 1")
        open(app.buttons["course.page.Exam 1"], titled: "Exam 1", in: app)
        XCTAssertTrue(app.buttons["folder.Week 1"].appears(timeout: 5))
        XCTAssertLessThan(app.buttons["folder.Week 1"].frame.minY, app.buttons["folder.Week 2"].frame.minY)
    }

    @MainActor
    func testDayOneCourseMakesAndRemovesAnExamPage() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        app.navigationBars["NURS 310"].buttons["Home"].tap()
        app.buttons["home.course.NURS 220"].tap()
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["No pages yet. Tap + to make Page 1."].appears(timeout: 5))
        for name in ["Week 1", "Week 2", "Week 3"] {
            XCTAssertTrue(app.buttons["folder.\(name)"].exists, name)
        }
        XCTAssertLessThan(app.buttons["folder.Week 1"].frame.minY, app.buttons["folder.Week 2"].frame.minY)
        attach(app, "C day one")

        // Her order: Edit, then drag a folder by its grip onto another, then Done.
        tapVisible(app.buttons["course.editFolders"], in: app)
        let week3 = app.otherElements["reorder.Week 3"]
        waitUntilStill(week3)
        week3.press(forDuration: 1, thenDragTo: app.otherElements["reorder.Week 1"], withVelocity: .slow, thenHoldForDuration: 0.5)
        let first = NSPredicate(format: "isEnabled == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: first, evaluatedWith: app.buttons["reorder.up.Week 3"])], timeout: 5), .completed, "now first")
        attach(app, "C folders, order")
        app.buttons["course.editFolders"].tap()
        XCTAssertTrue(app.buttons["folder.Week 3"].appears(timeout: 5))
        XCTAssertLessThan(app.buttons["folder.Week 3"].frame.minY, app.buttons["folder.Week 1"].frame.minY)

        // The +'s New page: a page with two of her folders.
        app.buttons["course.add"].tap()
        chooseFromMenu(app.buttons["course.add.page"])
        XCTAssertTrue(app.navigationBars["New page"].appears(timeout: 5))
        XCTAssertEqual(app.textFields["editPage.name"].value as? String, "Page 1")
        XCTAssertEqual(app.staticTexts["editPage.line"].label, "No folders yet")
        app.buttons["editPage.chip.free.Week 1"].tap()
        app.buttons["editPage.chip.free.Week 2"].tap()
        XCTAssertEqual(app.staticTexts["editPage.line"].label, "2 folders · 85 questions")
        attach(app, "C new exam page")
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Page 1"].appears(timeout: 10), "a new page opens")
        XCTAssertEqual(app.staticTexts["page.note"].label, "2 folders · 2 practice sets · 85 questions")
        XCTAssertFalse(app.descendants(matching: .any)["page.twins"].exists, "no folder on this page has exam twins")
        XCTAssertTrue(app.staticTexts["Exams you finish over Page 1 show up here with their scores."].exists)
        attach(app, "C exam page, new")

        goBack(app, from: "Page 1")
        XCTAssertTrue(app.buttons["course.page.Page 1"].appears(timeout: 5))
        XCTAssertFalse(app.buttons["folder.Week 1"].exists)
        XCTAssertTrue(app.buttons["folder.Week 3"].exists)

        // Deleting the page puts its folders under Folders; no set moves.
        app.buttons["course.page.Page 1"].tap()
        app.buttons["page.edit"].tap()
        app.buttons["page.editPage"].tap()
        XCTAssertTrue(app.navigationBars["Edit Page 1"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["editPage.chip.free.Week 3"].exists)
        attach(app, "C edit exam page")
        tapVisible(app.buttons["editPage.delete"], in: app)
        XCTAssertTrue(app.staticTexts["deleteSheet.message"].appears(timeout: 5))
        XCTAssertEqual(app.staticTexts["deleteSheet.message"].label, "Its 2 folders stay, with their sets and your progress, under Folders: Week 1 and Week 2. You can undo this for 30 days.")
        tapWhenStill(app.buttons["deleteSheet.confirm"])
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 10), "a deleted page closes")
        XCTAssertTrue(app.staticTexts["No pages yet. Tap + to make Page 1."].appears(timeout: 5))
        XCTAssertTrue(app.buttons["folder.Week 1"].exists)
    }

    @MainActor
    func testFoldersEditShowsOnlyWhereFoldersCanBeOrdered() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))

        // One folder on no exam page: nothing to order, so no Edit, and no line about a connection.
        XCTAssertTrue(app.staticTexts["Folders on no page. Open one to see its sets."].appears(timeout: 5))
        XCTAssertFalse(app.buttons["course.editFolders"].exists)
        XCTAssertFalse(app.staticTexts["course.orderNeedsConnection"].exists)
        attach(app, "C folders, one loose folder")

        // A second one: Edit shows up and puts the list in order.
        openFolder(app, "Week 3", on: "Exam 2")
        app.buttons["folder.page"].tap()
        app.buttons["examPage.none"].tap()
        app.buttons["examPage.save"].tap()
        waitForLabel(app.staticTexts["folder.note"], containing: "On no page")
        goBack(app, from: "Week 3")
        goBack(app, from: "Exam 2")
        let edit = app.buttons["course.editFolders"]
        tapVisible(edit, in: app)
        XCTAssertTrue(app.buttons["reorder.up.Week 3"].appears(timeout: 5))
        XCTAssertEqual(edit.label, "Done, save folder order")
        edit.tap()
        XCTAssertTrue(app.buttons["folder.Week 3"].appears(timeout: 5))
        XCTAssertEqual(edit.label, "Edit folder order")

        // Without a connection it cannot be saved: no Edit, and a line that says why.
        setNetwork(online: false)
        let line = app.staticTexts["course.orderNeedsConnection"]
        XCTAssertTrue(line.appears(timeout: 10))
        XCTAssertEqual(line.label, "Putting folders in order needs a connection.")
        XCTAssertFalse(edit.exists)
        attach(app, "C folders, offline")
        setNetwork(online: true)
        XCTAssertTrue(edit.appears(timeout: 10))
        XCTAssertFalse(line.exists)
    }

    // MARK: Helpers

    /// Opens one of the course's three tiles from the course she landed on.
    @MainActor
    private func openTile(_ app: XCUIApplication, _ tile: String, title: String) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        let button = app.buttons["course.tile.\(tile)"]
        XCTAssertTrue(button.appears(timeout: 5))
        button.tap()
        XCTAssertTrue(app.navigationBars[title].appears(timeout: 5))
    }

    /// Whether a text shows, as one element or as part of a combined one, in any letter case.
    @MainActor
    private func hasText(_ app: XCUIApplication, _ text: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", text)).firstMatch.appears(timeout: 5)
    }

    @MainActor
    private func expectCount(_ app: XCUIApplication, _ count: String) {
        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.appears(timeout: 5))
        let changed = NSPredicate(format: "label BEGINSWITH %@", "\(count),")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: counter)], timeout: 5), .completed, "count is \(counter.label)")
    }

    @MainActor
    private func submit(_ app: XCUIApplication, next: String) {
        let button = app.buttons["exam.submit"]
        XCTAssertTrue(button.isEnabled)
        button.tap()
        expectCount(app, next)
    }

    /// Flips a switch by its knob, which a tap on the middle of the row does not reach.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.appears(timeout: 5))
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: flipped, evaluatedWith: toggle)], timeout: 5), .completed)
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
