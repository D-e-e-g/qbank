import Foundation
import Testing

@testable import QBankKit

/// The refusals of deleting and Undo, in the server's words, and what a deleted thing looks like while it is deleted. Invented data only.
@Suite struct LocalBankUndoTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: In use

    @Test func anExamInProgressHoldsTheSetsItAsksAndTheFoldersAndCourseItIsIn() async throws {
        let world = try await DeleteWorld()
        try world.insertExam("e0000000-0000-4000-8000-000000000001", folders: [world.week1], questions: world.heartExam.questions)
        let before = try world.snapshot()

        let exam = "/api/practice-sets/\(world.heartExam.setID)"
        let preview = try await world.send("GET", exam + "/delete-preview")
        #expect(preview.body["refusal"] == .string("An exam in progress asks questions from Heart A exam. Finish or leave that exam first."))
        let confirm = try #require(preview.body["confirm"]?.stringValue)
        #expect(words(try await world.send("DELETE", "\(exam)?confirm=\(confirm)")) == "409 in_use An exam in progress asks questions from Heart A exam. Finish or leave that exam first.")
        // The refusal comes before the confirmation is looked at.
        #expect(try await world.send("DELETE", exam).body["error"] == .string("in_use"))

        let folder = try await world.send("GET", "/api/folders/\(world.week1)/delete-preview")
        #expect(folder.body["refusal"] == .string("An exam in progress asks questions from Week 1. Finish or leave that exam first."))
        #expect(try await world.send("DELETE", "/api/folders/\(world.week1)?confirm=\(try #require(folder.body["confirm"]?.stringValue))").status == 409)

        let course = try await world.send("GET", "/api/courses/\(world.course)/delete-preview")
        #expect(course.body["refusal"] == .string("An exam in NURS 101 is still going. Finish or leave that exam first."))
        #expect(words(try await world.send("DELETE", "/api/courses/\(world.course)?confirm=\(try #require(course.body["confirm"]?.stringValue))")) == "409 in_use An exam in NURS 101 is still going. Finish or leave that exam first.")
        #expect(try world.snapshot() == before, "a refused delete writes nothing")

        // What the exam does not ask is free: the other set, the other folder, and the page, which only names its folders.
        #expect(try await world.confirmedDelete("/api/practice-sets/\(world.lungs.setID)").status == 204)
        #expect(try await world.confirmedDelete("/api/folders/\(world.week2)").status == 204)
        #expect(try await world.confirmedDelete("/api/course-exams/\(world.page)").status == 204)
    }

    @Test func anExamStopsHoldingOnceItIsEndedOrItsTimeAndGraceAreUp() async throws {
        let world = try await DeleteWorld()
        try world.insertExam("e0000000-0000-4000-8000-000000000001", folders: [world.week1], questions: world.heartA.questions, limit: 600)
        let preview = { try await world.send("GET", "/api/practice-sets/\(world.heartA.setID)/delete-preview").body["refusal"] }
        #expect(try await preview() != .null)
        // Its time ran out, and the 30 seconds an answer is still taken in have not.
        world.harness.set(start.addingTimeInterval(630))
        #expect(try await preview() != .null)
        world.harness.set(start.addingTimeInterval(631))
        #expect(try await preview() == .null)
        #expect(try await world.send("GET", "/api/courses/\(world.course)/delete-preview").body["refusal"] == .null)

        let ended = try await DeleteWorld()
        try ended.insertExam("e0000000-0000-4000-8000-000000000002", folders: [ended.week1], questions: ended.heartA.questions, finished: true)
        #expect(try await ended.send("GET", "/api/practice-sets/\(ended.heartA.setID)/delete-preview").body["refusal"] == .null)
    }

    @Test func aPageIsRefusedWhileOneOfItsFoldersHasTheNameOfOneInTheFoldersList() async throws {
        let world = try await DeleteWorld()
        let twin = try await world.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("Week 2")]))
        #expect(twin.status == 409, "a folder list holds one of each name")
        let renamed = try await world.send("PATCH", "/api/folders/\(world.week2)", .object(["name": .string("Week 1")]))
        #expect(renamed.status == 200, "Week 1 is on the page, so the Folders list has none of that name")
        let preview = try await world.send("GET", "/api/course-exams/\(world.page)/delete-preview")
        let message = "NURS 101 already has a folder named Week 1 in its Folders list. Rename one of them before deleting Exam 1."
        #expect(preview.body["refusal"] == .string(message))
        let confirm = try #require(preview.body["confirm"]?.stringValue)
        #expect(words(try await world.send("DELETE", "/api/course-exams/\(world.page)?confirm=\(confirm)")) == "409 request_refused \(message)")
    }

    // MARK: Undo's refusals

    @Test func undoRunsOutAfterThirtyDaysAndNothingIsRemovedWhenItDoes() async throws {
        let world = try await DeleteWorld()
        #expect(try await world.confirmedDelete("/api/practice-sets/\(world.heartB.setID)").status == 204)
        #expect(try await world.confirmedDelete("/api/folders/\(world.week2)").status == 204)
        #expect(try await world.confirmedDelete("/api/course-exams/\(world.page)").status == 204)
        #expect(try await world.confirmedDelete("/api/courses/\(world.topic)").status == 204)
        let hidden = try world.snapshot()
        world.advance(days: 30.001)
        #expect(words(try await world.send("POST", "/api/practice-sets/\(world.heartB.setID)/undo-delete")) == "409 undo_expired Heart B was deleted more than 30 days ago, so it can't be brought back.")
        #expect(words(try await world.send("POST", "/api/folders/\(world.week2)/undo-delete")) == "409 undo_expired Week 2 was deleted more than 30 days ago, so it can't be brought back.")
        #expect(words(try await world.send("POST", "/api/course-exams/\(world.page)/undo-delete")) == "409 undo_expired Exam 1 was deleted more than 30 days ago, so it can't be brought back.")
        #expect(words(try await world.send("POST", "/api/courses/\(world.topic)/undo-delete")) == "409 undo_expired Pharmacology was deleted more than 30 days ago, so it can't be brought back.")
        #expect(try world.snapshot() == hidden, "an expired delete stays hidden and nothing is removed")
        // Exactly 30 days is still in time.
        let thirty = try await DeleteWorld()
        #expect(try await thirty.confirmedDelete("/api/practice-sets/\(thirty.heartB.setID)").status == 204)
        thirty.advance(days: 30)
        #expect(try await thirty.send("POST", "/api/practice-sets/\(thirty.heartB.setID)/undo-delete").status == 200)
    }

    @Test func aSetThatWentWithItsFolderOrWhoseFolderWasDeletedAfterwardIsBroughtBackThroughTheFolder() async throws {
        let world = try await DeleteWorld()
        #expect(try await world.confirmedDelete("/api/folders/\(world.week1)").status == 204)
        #expect(words(try await world.send("POST", "/api/practice-sets/\(world.heartA.setID)/undo-delete")) == "409 request_refused Heart A went with its folder Week 1. Bring the folder back to bring it back.")

        let other = try await DeleteWorld()
        #expect(try await other.confirmedDelete("/api/practice-sets/\(other.heartA.setID)").status == 204)
        #expect(try await other.confirmedDelete("/api/folders/\(other.week1)").status == 204)
        #expect(words(try await other.send("POST", "/api/practice-sets/\(other.heartA.setID)/undo-delete")) == "409 request_refused Its folder Week 1 is deleted. Bring the folder back first.")
        // The folder comes back without the set that was deleted before it; the set then comes back on its own.
        let folder = try await other.send("POST", "/api/folders/\(other.week1)/undo-delete")
        #expect(folder.body["sets"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Heart B"])
        let set = try await other.send("POST", "/api/practice-sets/\(other.heartA.setID)/undo-delete")
        #expect(set.status == 200 && set.body["sets"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Heart A", "Heart B"])
    }

    @Test func aFolderPageCourseOrTopicWhoseNameIsTakenMeanwhileCannotComeBackUntilOneIsRenamed() async throws {
        let world = try await DeleteWorld()
        #expect(try await world.confirmedDelete("/api/folders/\(world.week2)").status == 204)
        let folder = try await world.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("week 2")]))
        #expect(folder.status == 201)
        #expect(words(try await world.send("POST", "/api/folders/\(world.week2)/undo-delete")) == "409 request_refused NURS 101 already has a folder named week 2. Rename one of them, then bring this one back.")

        #expect(try await world.confirmedDelete("/api/course-exams/\(world.page)").status == 204)
        let page = try await world.send("POST", "/api/courses/\(world.course)/course-exams", .object(["name": .string("exam 1")]))
        #expect(page.status == 201)
        #expect(words(try await world.send("POST", "/api/course-exams/\(world.page)/undo-delete")) == "409 request_refused This course already has a page named exam 1. Rename one of them, then bring this one back.")

        #expect(try await world.confirmedDelete("/api/courses/\(world.topic)").status == 204)
        let topic = try await world.send("POST", "/api/topics", .object(["title": .string("PHARMACOLOGY")]))
        #expect(topic.status == 201)
        #expect(words(try await world.send("POST", "/api/courses/\(world.topic)/undo-delete")) == "409 request_refused You already have a topic named PHARMACOLOGY. Rename one of them, then bring this one back.")

        #expect(try await world.confirmedDelete("/api/courses/\(world.course)").status == 204)
        let semesters = try await world.send("GET", "/api/semesters")
        let semester = try #require(semesters.body["semesters"]?.arrayValue?.first?["id"])
        let course = try await world.send("POST", "/api/courses", .object(["semesterId": semester, "code": .string("nurs 101"), "title": .string("Again")]))
        #expect(course.status == 201)
        #expect(words(try await world.send("POST", "/api/courses/\(world.course)/undo-delete")) == "409 request_refused Semester 1 already has a course with the code nurs 101. Rename one of them, then bring this one back.")
        // Renaming the new one frees the old one's code.
        let renamed = try await world.send("PATCH", "/api/courses/\(try #require(course.body["id"]?.stringValue))", .object(["code": .string("NURS 102")]))
        #expect(renamed.status == 200)
        #expect(try await world.send("POST", "/api/courses/\(world.course)/undo-delete").status == 200)
    }

    @Test func undoOfSomethingNotDeletedOrNotThereIsRefused() async throws {
        let world = try await DeleteWorld()
        #expect(words(try await world.send("POST", "/api/practice-sets/\(world.heartA.setID)/undo-delete")) == "409 request_refused That set is not deleted.")
        #expect(words(try await world.send("POST", "/api/folders/\(world.week1)/undo-delete")) == "409 request_refused That folder is not deleted.")
        #expect(words(try await world.send("POST", "/api/course-exams/\(world.page)/undo-delete")) == "409 request_refused Exam 1 is not deleted.")
        #expect(words(try await world.send("POST", "/api/courses/\(world.course)/undo-delete")) == "409 request_refused NURS 101 is not deleted.")
        let nothing = "00000000-0000-4000-8000-000000000000"
        #expect(words(try await world.send("POST", "/api/practice-sets/\(nothing)/undo-delete")) == "404 request_refused That set is not in the app.")
        #expect(words(try await world.send("POST", "/api/folders/\(nothing)/undo-delete")) == "404 request_refused That folder is not in the app.")
        #expect(words(try await world.send("POST", "/api/course-exams/\(nothing)/undo-delete")) == "404 request_refused That page is not in the app.")
        #expect(words(try await world.send("POST", "/api/courses/\(nothing)/undo-delete")) == "404 request_refused That course is not in the app.")
    }

    // MARK: While deleted

    @Test func aDeletedSetCountsForNothingAndItsAnswersCountAgainOnceItIsBack() async throws {
        let world = try await DeleteWorld()
        let card = { try await world.send("GET", "/api/courses/\(world.course)").body }
        let before = try await card()
        let progress = try world.harness.rows("SELECT * FROM question_progress")
        #expect(try await world.confirmedDelete("/api/practice-sets/\(world.heartA.setID)").status == 204)
        let during = try await card()
        #expect(during["answeredCount"] == .number(1) && during["questionCount"] == .number(4) && during["reviewCount"] == .number(0))
        #expect(try world.harness.rows("SELECT * FROM question_progress") == progress, "her answers stay saved")
        #expect(words(try await world.send("GET", "/api/practice-sets/\(world.heartA.setID)")) == "404 request_refused That set was deleted.")
        #expect(try await world.send("POST", "/api/practice-sets/\(world.heartA.setID)/undo-delete").status == 200)
        #expect(try await card() == before)
    }

    @Test func aDeletedCourseLeavesHomeAndTheLastCourseUsedAndComesBackWhole() async throws {
        let world = try await DeleteWorld()
        _ = try await world.send("PUT", "/api/me/place", .object(["courseId": .string(world.course)]))
        let home = try await world.send("GET", "/api/semesters").body
        #expect(try await world.confirmedDelete("/api/courses/\(world.course)").status == 204)
        let during = try await world.send("GET", "/api/semesters").body
        #expect(during["semesters"]?.arrayValue?.first?["courses"] == .array([]))
        #expect(words(try await world.send("GET", "/api/courses/\(world.course)")) == "404 request_refused That course is not in the app.")
        #expect(try await world.send("GET", "/api/me/place").body == .object(["courseId": .null]))
        let listed = try await world.send("GET", "/api/deleted-courses")
        #expect(listed.body["undoDays"] == .number(30) && listed.body["courses"]?.arrayValue?.compactMap { $0["code"]?.stringValue } == ["NURS 101"])
        let back = try await world.send("POST", "/api/courses/\(world.course)/undo-delete")
        #expect(back.status == 200 && back.body["questionCount"] == .number(7) && back.body["answeredCount"] == .number(4))
        #expect(try await world.send("GET", "/api/semesters").body == home)
        #expect(try await world.send("GET", "/api/me/place").body == .object(["courseId": .string(world.course)]))
        #expect(try await world.send("GET", "/api/deleted-courses").body["courses"] == .array([]))
    }

    // MARK: Recently deleted

    @Test func recentlyDeletedListsEachDeleteOnceNewestFirstAndOnlyForThirtyDays() async throws {
        let world = try await DeleteWorld()
        #expect(try await world.confirmedDelete("/api/folders/\(world.week1)").status == 204)
        world.advance(days: 1)
        #expect(try await world.confirmedDelete("/api/practice-sets/\(world.lungs.setID)").status == 204)
        world.advance(days: 2)
        #expect(try await world.confirmedDelete("/api/course-exams/\(world.page)").status == 204)
        let listed = try await world.send("GET", "/api/courses/\(world.course)/deleted")
        #expect(listed.status == 200 && listed.body["undoDays"] == .number(30) && listed.body["exams"] == .array([]))
        let folder = try #require(listed.body["folders"]?.arrayValue?.first)
        #expect(folder["name"] == .string("Week 1") && folder["examPageId"] == .null, "its page was deleted since, so it comes back to the Folders list")
        #expect(folder["sets"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Heart A", "Heart B", "Heart A exam"])
        #expect(folder["sets"]?.arrayValue?.compactMap { $0["questionCount"] } == [.number(3), .number(2), .number(2)])
        #expect(folder["undoRefusal"] == .null && folder["deletedByAgent"] == .null)
        #expect(folder["deletedAt"] == .string(QBankJSON.formatDate(start)) && folder["undoUntil"] == .string(QBankJSON.formatDate(start.addingTimeInterval(30 * 86_400))))
        let sets = try #require(listed.body["sets"]?.arrayValue)
        #expect(sets.count == 1 && sets[0]["title"] == .string("Lungs") && sets[0]["folderName"] == .string("Week 2") && sets[0]["folderId"] == .string(world.week2))
        let pages = try #require(listed.body["examPages"]?.arrayValue)
        #expect(pages.count == 1 && pages[0]["name"] == .string("Exam 1") && pages[0]["badge"] == .null && pages[0]["pastExamCount"] == .number(0))
        #expect(pages[0]["folders"] == .array([]), "its folder is deleted, so it names none to put back")

        // Days from the first delete: the folder is 31.5 days old, the set 30.5, the page 29.5.
        world.advance(days: 31.5)
        let later = try await world.send("GET", "/api/courses/\(world.course)/deleted").body
        #expect(later["folders"] == .array([]) && later["sets"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == [] && later["examPages"]?.arrayValue?.count == 1)
        world.advance(days: 33)
        #expect(try await world.send("GET", "/api/courses/\(world.course)/deleted").body["examPages"] == .array([]))
    }

    @Test func aDeletedItemSaysWhyUndoWouldBeRefusedNow() async throws {
        let world = try await DeleteWorld()
        #expect(try await world.confirmedDelete("/api/practice-sets/\(world.heartA.setID)").status == 204)
        #expect(try await world.confirmedDelete("/api/folders/\(world.week1)").status == 204)
        // A folder of that name on the page it would go back to.
        let made = try await world.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("week 1"), "examPageId": .string(world.page)]))
        #expect(made.status == 201)
        let listed = try await world.send("GET", "/api/courses/\(world.course)/deleted").body
        #expect(listed["folders"]?.arrayValue?.first?["undoRefusal"] == .string("Exam 1 already has a folder named week 1. Rename one of them, then bring this one back."))
        // The set deleted before the folder is listed on its own, and its folder being deleted is why it cannot come back yet.
        let sets = try #require(listed["sets"]?.arrayValue)
        #expect(sets.count == 1 && sets[0]["title"] == .string("Heart A"))
        #expect(sets[0]["undoRefusal"] == .string("Its folder Week 1 is deleted. Bring the folder back first."))
        #expect(listed["folders"]?.arrayValue?.first?["sets"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Heart B", "Heart A exam"])
    }
}
