import Foundation
import Testing

@testable import QBankKit

/// Deleting and Undo on the phone, over a bank built through the engine's own routes from invented data. The transcripts prove each
/// delete's words and shapes against the server's recordings; these prove what no recording can say row by row: that Undo leaves every
/// table as it was, that nothing is ever removed, and the refusals in their own words.
@Suite struct LocalBankDeleteTests {
    // MARK: Undo leaves every table as it was

    /// A delete and its Undo, each by its own routes, for one thing of the world.
    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String { name }
        let name: String
        let path: @Sendable (DeleteWorld) -> String
        let undo: @Sendable (DeleteWorld) -> String
    }

    static let cases: [Case] = [
        Case(name: "a set", path: { "/api/practice-sets/\($0.heartA.setID)" }, undo: { "/api/practice-sets/\($0.heartA.setID)/undo-delete" }),
        Case(name: "an exam set", path: { "/api/practice-sets/\($0.heartExam.setID)" }, undo: { "/api/practice-sets/\($0.heartExam.setID)/undo-delete" }),
        Case(name: "a folder", path: { "/api/folders/\($0.week1)" }, undo: { "/api/folders/\($0.week1)/undo-delete" }),
        Case(name: "a folder on no page", path: { "/api/folders/\($0.week2)" }, undo: { "/api/folders/\($0.week2)/undo-delete" }),
        Case(name: "a page", path: { "/api/course-exams/\($0.page)" }, undo: { "/api/course-exams/\($0.page)/undo-delete" }),
        Case(name: "a course", path: { "/api/courses/\($0.course)" }, undo: { "/api/courses/\($0.course)/undo-delete" }),
        Case(name: "a topic", path: { "/api/courses/\($0.topic)" }, undo: { "/api/courses/\($0.topic)/undo-delete" }),
    ]

    @Test(arguments: cases)
    func undoLeavesEveryTableRowForRowAsItWas(_ item: Case) async throws {
        let world = try await DeleteWorld()
        let before = try world.snapshot()
        let counts = before.mapValues(\.count)

        let deleted = try await world.confirmedDelete(item.path(world))
        #expect(deleted.status == 204 && deleted.body == .null, "\(item.name): \(deleted.body)")
        let hidden = try world.snapshot()
        #expect(hidden != before, "\(item.name) is hidden while deleted")
        #expect(hidden.mapValues(\.count) == counts, "\(item.name): a delete removes no row")

        world.advance(days: 29)
        let undone = try await world.send("POST", item.undo(world))
        #expect(undone.status == 200, "\(item.name): \(undone.body)")
        for table in DeleteWorld.tables { #expect(try world.snapshot()[table] == before[table], "\(item.name): \(table) is as it was") }
    }

    @Test func everythingDeletedAtOnceIsBroughtBackInAnyOrder() async throws {
        let world = try await DeleteWorld()
        let before = try world.snapshot()
        let deletes = [
            "/api/practice-sets/\(world.heartB.setID)", "/api/folders/\(world.week2)", "/api/course-exams/\(world.page)", "/api/folders/\(world.week1)",
            "/api/courses/\(world.topic)", "/api/courses/\(world.course)",
        ]
        for path in deletes { #expect(try await world.confirmedDelete(path).status == 204, "\(path)") }
        #expect(try world.snapshot().mapValues(\.count) == before.mapValues(\.count))
        // The course first (the sets and folders come back inside it), then its folders and its page, then the set that went alone.
        for path in [
            "/api/courses/\(world.topic)", "/api/courses/\(world.course)", "/api/course-exams/\(world.page)", "/api/folders/\(world.week1)",
            "/api/folders/\(world.week2)", "/api/practice-sets/\(world.heartB.setID)",
        ] {
            let undone = try await world.send("POST", path + "/undo-delete")
            #expect(undone.status == 200, "\(path) \(undone.body)")
        }
        #expect(try world.snapshot() == before)
    }

    @Test func aDeleteReadsTheSameWhenTheClockMovedBetweenTheStepsAsItWouldInOneBreath() async throws {
        let world = try await DeleteWorld()
        let before = try world.snapshot()
        let preview = try await world.send("GET", "/api/folders/\(world.week1)/delete-preview")
        world.advance(days: 3)
        let deleted = try await world.send("DELETE", "/api/folders/\(world.week1)?confirm=\(preview.body["confirm"]?.stringValue ?? "")")
        #expect(deleted.status == 204)
        #expect(try world.snapshot() != before)
        world.advance(days: 5)
        #expect(try await world.send("POST", "/api/folders/\(world.week1)/undo-delete").status == 200)
        #expect(try world.snapshot() == before)
    }

    // MARK: Confirming

    @Test func aDeleteWithoutItsConfirmOrWithAStaleOneDeletesNothing() async throws {
        let world = try await DeleteWorld()
        let before = try world.snapshot()
        let set = "/api/practice-sets/\(world.heartA.setID)"
        #expect(words(try await world.send("DELETE", set)) == "409 confirmation_required Look at what goes with Heart A and confirm it before deleting it.")
        #expect(words(try await world.send("DELETE", set + "?confirm=0000000000000000")) == "409 deletion_changed Heart A changed since you were warned. Look again before deleting it.")
        let folder = "/api/folders/\(world.week1)"
        #expect(
            words(try await world.send("DELETE", folder))
                == "409 confirmation_required Week 1 still has 3 sets. Deleting it deletes them too, so look at what goes and confirm it first.")
        let page = "/api/course-exams/\(world.page)"
        #expect(
            words(try await world.send("DELETE", page))
                == "409 confirmation_required Exam 1 still has 1 folder. Deleting it puts that folder under Folders, so look at what changes and confirm it first.")
        #expect(words(try await world.send("DELETE", "/api/courses/\(world.course)")) == "409 confirmation_required Look at what goes with NURS 101 and confirm it before deleting it.")
        #expect(try world.snapshot() == before)

        // What the warning named changed since: a set moved out of the folder.
        let preview = try await world.send("GET", folder + "/delete-preview")
        let moved = try await world.send("POST", "/api/practice-sets/\(world.heartB.setID)/move", .object(["folderId": .string(world.week2)]))
        #expect(moved.status == 200)
        let stale = try await world.send("DELETE", "\(folder)?confirm=\(preview.body["confirm"]?.stringValue ?? "")")
        #expect(words(stale) == "409 deletion_changed Week 1 changed since you were warned. Look again before deleting it.")
    }

    @Test func anEmptyFolderAndAPageWithNoFoldersGoWithoutAConfirm() async throws {
        let world = try await DeleteWorld()
        let empty = try await world.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("Spare")]))
        let id = try #require(empty.body["id"]?.stringValue)
        #expect(try await world.send("DELETE", "/api/folders/\(id)").status == 204)
        let bare = try await world.send("POST", "/api/courses/\(world.course)/course-exams", .object(["name": .string("Exam 9")]))
        #expect(try await world.send("DELETE", "/api/course-exams/\(try #require(bare.body["id"]?.stringValue))").status == 204)
        // Handing a confirm over anyway still has to match.
        let again = try await world.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("Spare")]))
        let spare = try #require(again.body["id"]?.stringValue)
        #expect(words(try await world.send("DELETE", "/api/folders/\(spare)?confirm=nope")) == "409 deletion_changed Spare changed since you were warned. Look again before deleting it.")
    }

    // MARK: What the previews say

    @Test func aSetsPreviewNamesWhatGoesAndHowTheStandingChanges() async throws {
        let world = try await DeleteWorld()
        let preview = try await world.send("GET", "/api/practice-sets/\(world.heartA.setID)/delete-preview")
        #expect(preview.status == 200)
        #expect(preview.body["message"] == .string("Delete Heart A? Its 3 questions go with it. You have answered 3 of them: those answers stop counting toward your progress, and 2 questions leave your Review list. You can undo this for 30 days."))
        #expect(preview.body["warning"] == .object(["title": .string("Delete Heart A?"), "body": .string("Its 3 questions go with it. You have answered 3 of them: those answers stop counting toward your progress, and 2 questions leave your Review list. You can undo this for 30 days.")]))
        #expect(preview.body["questionCount"] == .number(3) && preview.body["versionCount"] == .number(1) && preview.body["answeredCount"] == .number(3) && preview.body["reviewCount"] == .number(2))
        #expect(preview.body["folderName"] == .string("Week 1") && preview.body["examPageId"] == .string(world.page) && preview.body["refusal"] == .null && preview.body["undoDays"] == .number(30))
        // The course answered 4 practice questions (Heart A's three and Lungs' one), got 3 fully right (a guess still is), has 2 in Review, and none wrong: Week 1 has an exam bank, so its Wrong questions come from exam questions alone.
        func change(_ key: String) -> (Double, Double)? {
            guard case .number(let before)? = preview.body["progress"]?[key]?["before"], case .number(let after)? = preview.body["progress"]?[key]?["after"] else { return nil }
            return (before, after)
        }
        #expect(change("answeredCount")! == (4, 1) && change("fullyRightCount")! == (3, 1) && change("reviewCount")! == (2, 0) && change("wrongCount")! == (0, 0))

        let exam = try await world.send("GET", "/api/practice-sets/\(world.heartExam.setID)/delete-preview")
        #expect(exam.body["message"] == .string("Delete Heart A exam from Week 1's exam bank? Its 2 questions go with it, and exams over Week 1 go back to asking its practice questions. You can undo this for 30 days."))
    }

    @Test func aFoldersPreviewListsItsSetsPracticeFirstAndTheCourseNamesWhatItHolds() async throws {
        let world = try await DeleteWorld()
        let folder = try await world.send("GET", "/api/folders/\(world.week1)/delete-preview")
        #expect(folder.body["sets"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Heart A", "Heart B", "Heart A exam"])
        #expect(folder.body["examPageName"] == .string("Exam 1") && folder.body["setCount"] == .number(3) && folder.body["questionCount"] == .number(7))
        #expect(folder.body["message"]?.stringValue?.contains("Its 3 sets go with it: Heart A, Heart B and Heart A exam, 7 questions in all.") == true)
        #expect(folder.body["message"]?.stringValue?.contains("It comes off Exam 1.") == true)

        let course = try await world.send("GET", "/api/courses/\(world.course)/delete-preview")
        #expect(course.body["message"] == .string("Delete NURS 101 and its 7 questions? You can bring it back for 30 days."))
        #expect(course.body["folderCount"] == .number(2) && course.body["examPageCount"] == .number(1) && course.body["setCount"] == .number(4))
        #expect(course.body["questionCount"] == .number(7) && course.body["examQuestionCount"] == .number(2) && course.body["answeredCount"] == .number(4))
        #expect(course.body["semester"]?["number"] == .number(1) && course.body["pastExamCount"] == .number(0))
        let topic = try await world.send("GET", "/api/courses/\(world.topic)/delete-preview")
        #expect(topic.body["message"] == .string("Delete Pharmacology and its 2 questions? You can bring it back for 30 days.") && topic.body["semester"] == .null && topic.body["code"] == .string(""))
    }

    @Test func aPagesPreviewKeepsTheStandingAndNamesThePastExamsOverIt() async throws {
        let world = try await DeleteWorld()
        try world.insertExam("e0000000-0000-4000-8000-000000000001", folders: [world.week1], questions: [world.heartA.questions[0]], finished: true)
        try world.insertExam("e0000000-0000-4000-8000-000000000002", folders: [world.week2], questions: [world.lungs.questions[0]], finished: true)
        let preview = try await world.send("GET", "/api/course-exams/\(world.page)/delete-preview")
        #expect(preview.body["message"] == .string("Delete Exam 1? Its folder Week 1 stays, with its sets and your progress, under Folders. Your 1 past exam over it stays. You can undo this for 30 days."))
        #expect(preview.body["pastExamCount"] == .number(1) && preview.body["folderCount"] == .number(1) && preview.body["setCount"] == .number(3))
        #expect(preview.body["questionCount"] == .number(5) && preview.body["examQuestionCount"] == .number(2) && preview.body["answeredCount"] == .number(3))
        #expect(preview.body["progress"]?["answeredCount"] == .object(["before": .number(4), "after": .number(4)]))

        // The folder's past exams count the one still going too; the page's do not.
        try world.insertExam("e0000000-0000-4000-8000-000000000003", folders: [world.week1], questions: [world.heartA.questions[1]])
        let folder = try await world.send("GET", "/api/folders/\(world.week1)/delete-preview")
        #expect(folder.body["pastExamCount"] == .number(2))
        #expect(try await world.send("GET", "/api/course-exams/\(world.page)/delete-preview").body["pastExamCount"] == .number(1))
        #expect(try await world.send("GET", "/api/courses/\(world.course)/delete-preview").body["pastExamCount"] == .number(3))
    }

    @Test func aPreviewOfAThingThatIsNotThereIsRefusedInTheServersWords() async throws {
        let world = try await DeleteWorld()
        let nothing = "00000000-0000-4000-8000-000000000000"
        #expect(words(try await world.send("GET", "/api/practice-sets/\(nothing)/delete-preview")) == "404 request_refused That set is not in the app.")
        #expect(words(try await world.send("GET", "/api/folders/\(nothing)/delete-preview")) == "404 request_refused That folder is not in the app.")
        #expect(words(try await world.send("GET", "/api/courses/\(nothing)/delete-preview")) == "404 request_refused That course is not in the app.")
        let recorded = try Fixture.load("course-exam-not-found").response
        let page = try await world.send("GET", "/api/course-exams/\(nothing)/delete-preview")
        #expect(page.status == recorded.status && page.body == recorded.body)
        #expect(try await world.send("GET", "/api/practice-sets/not-an-id/delete-preview").status == 400)

        _ = try await world.confirmedDelete("/api/practice-sets/\(world.heartB.setID)")
        #expect(words(try await world.send("GET", "/api/practice-sets/\(world.heartB.setID)/delete-preview")) == "404 request_refused That set was deleted.")
        _ = try await world.confirmedDelete("/api/courses/\(world.course)")
        #expect(words(try await world.send("GET", "/api/folders/\(world.week2)/delete-preview")) == "404 request_refused That folder is not in the app.")
        #expect(words(try await world.send("GET", "/api/courses/\(world.course)/deleted")) == "404 course_not_found That course is not in the app.")
    }
}
