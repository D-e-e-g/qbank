import Foundation
import Testing

@testable import QBankKit

/// Deleting one of the past exams, and Undo, on the phone: what the preview says, what the delete
/// leaves, and that Undo gives back every table as it was. Invented data only.
@Suite struct LocalBankExamDeletionTests {
    /// A course with one folder of four questions (right at choices 0, 1, 2, 0), and an exam over it:
    /// the first question answered wrong in practice and right on the exam, the second and fourth
    /// answered only on the exam, the third answered right in practice only.
    private func world() async throws -> (world: ExamWorld, exam: String, questions: [String]) {
        var world = try await ExamWorld.make()
        let questions = try await world.addFolder("Week 1", questions: 4)
        world.at(1)
        try await world.answer(questions[0], choice: 1)
        try await world.answer(questions[2], choice: 2)
        world.at(10)
        let started = try await world.start(["Week 1"]).body
        let exam = try #require(started["id"]?.stringValue)
        world.at(20)
        try await world.answer(questions[0], choice: 0, exam: exam)
        try await world.answer(questions[1], choice: 1, exam: exam)
        try await world.answer(questions[3], choice: 1, exam: exam)
        world.at(30)
        #expect(try await world.finish(exam).status == 200)
        world.at(40)
        return (world, exam, questions)
    }

    private func snapshot(_ world: ExamWorld) throws -> [[[StoreValue]]] {
        try ["question_progress ORDER BY question_lineage_id", "study_session ORDER BY id", "attempt ORDER BY id", "review_clear ORDER BY question_lineage_id"].map {
            try world.harness.rows("SELECT * FROM \($0)")
        }
    }

    private func delete(_ world: ExamWorld, _ exam: String, confirm: String? = nil) async throws -> (status: Int, body: JSONValue) {
        try await world.harness.send("DELETE", "/api/exams/\(exam)\(confirm.map { "?confirm=\($0)" } ?? "")")
    }

    // MARK: The preview

    @Test func thePreviewSaysWhichAnswersGoBackAndWhichGoToNotAnswered() async throws {
        let (world, exam, _) = try await world()
        let preview = try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview")
        #expect(preview.status == 200)
        let body = preview.body
        #expect(body["answeredCount"] == .number(3) && body["changedCount"] == .number(1) && body["unansweredCount"] == .number(2) && body["questionCount"] == .number(4))
        let message =
            "Delete this exam? Your 3 answers on it go with it and stop counting toward your progress. 1 question goes back to your answer before it, and 2 questions go back to not answered. You can undo this for 30 days."
        #expect(body["message"] == .string(message))
        #expect(
            body["warning"]
                == .object([
                    "title": .string("Delete this exam?"), "body": .string(String(message.dropFirst("Delete this exam? ".count))),
                ]))
        #expect(body["refusal"] == .null && body["undoDays"] == .number(30) && body["startedAt"] == .string(world.time(10)) && body["finishedAt"] == .string(world.time(30)))
        let progress = try #require(body["progress"])
        func change(_ key: String) -> [JSONValue?] { [progress[key]?["before"], progress[key]?["after"]] }
        #expect(change("answeredCount") == [.number(4), .number(2)] && change("fullyRightCount") == [.number(3), .number(1)])
        #expect(change("reviewCount") == [.number(1), .number(1)] && change("points") == [.number(3), .number(1)] && change("maxPoints") == [.number(4), .number(2)])
        #expect(change("wrongCount") == [.number(1), .number(1)])
        // Looking changes nothing.
        #expect(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body["confirm"] == body["confirm"])
    }

    @Test func thePreviewNamesTheReviewListAndWrongQuestionsWhenTheyChange() async throws {
        var world = try await ExamWorld.make()
        let questions = try await world.addFolder("Week 1", questions: 2)
        world.at(1)
        try await world.answer(questions[0], choice: 1)
        world.at(10)
        let exam = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(20)
        try await world.answer(questions[0], choice: 0, exam: exam)
        world.at(30)
        _ = try await world.finish(exam)
        let message = try #require(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body["message"]?.stringValue)
        #expect(
            message
                == "Delete this exam? Your 1 answer on it goes with it and stops counting toward your progress. 1 question goes back to your answer before it. Your Review list goes from 0 to 1 question. Wrong questions go from 0 to 1. You can undo this for 30 days."
        )
    }

    @Test func anExamWithNoAnswersChangesNothingAndSaysSo() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let exam = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(5)
        _ = try await world.finish(exam, "left")
        let body = try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body
        #expect(body["message"] == .string("Delete this exam? You answered none of its questions, so your progress stays as it is. You can undo this for 30 days."))
        #expect(body["answeredCount"] == .number(0) && body["changedCount"] == .number(0) && body["unansweredCount"] == .number(0))
    }

    // MARK: The delete

    @Test func aDeleteNeedsTheConfirmThePreviewHandedOutAndIsRefusedWhenItNoLongerMatches() async throws {
        let (world, exam, _) = try await world()
        #expect(words(try await delete(world, exam)) == "409 confirmation_required Look at what deleting this exam changes and confirm it first.")
        #expect(
            words(try await delete(world, exam, confirm: "0000000000000000"))
                == "409 deletion_changed This exam changed since you were warned. Look again before deleting it.")
        #expect(try await delete(world, exam, confirm: String(repeating: "a", count: 65)).body["error"] == .string("invalid_request"))
        #expect(try world.count("study_session", "deleted_at IS NOT NULL") == 0)
        #expect(words(try await world.harness.send("DELETE", "/api/exams/00000000-0000-4000-8000-0000000000aa")) == "404 exam_not_found That exam is not in the app.")
    }

    @Test func aDeletedExamLeavesTheListAndItsAnswersStopCountingButStaySaved() async throws {
        let (world, exam, questions) = try await world()
        let confirm = try #require(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body["confirm"]?.stringValue)
        let answers = try world.count("attempt")
        let deleted = try await delete(world, exam, confirm: confirm)
        #expect(deleted.status == 204 && deleted.body == .null)
        #expect(words(try await world.read(exam)) == "404 exam_not_found That exam was deleted.")
        #expect(try await world.setup().body["exams"] == .array([]))
        #expect(words(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview")) == "404 exam_not_found That exam was deleted.")
        #expect(words(try await delete(world, exam, confirm: confirm)) == "404 exam_not_found That exam was deleted.")
        #expect(try world.count("attempt") == answers)
        // The first question is back at her practice answer, and the two answered only on the exam are not answered.
        let first = try #require(try world.progress(questions[0]))
        #expect(first.string("last_status") == "incorrect" && first.integer("attempts") == 1 && first.integer("correct_attempts") == 0 && first.bool("in_review") == true)
        #expect(try world.progress(questions[1]) == nil && world.progress(questions[3]) == nil)
        #expect(try #require(try world.progress(questions[2])).string("last_status") == "correct")
        let course = try await world.harness.send("GET", "/api/courses/\(world.course)")
        #expect(course.body["answeredCount"] == .number(2) && course.body["fullyRightCount"] == .number(1) && course.body["reviewCount"] == .number(1))
    }

    @Test func undoGivesBackEveryTableAsItWasBeforeTheDelete() async throws {
        let (world, exam, _) = try await world()
        let before = try snapshot(world)
        let confirm = try #require(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body["confirm"]?.stringValue)
        _ = try await delete(world, exam, confirm: confirm)
        #expect(try snapshot(world) != before)
        world.at(50)
        let undone = try await world.harness.send("POST", "/api/exams/\(exam)/undo-delete")
        #expect(undone.status == 200 && undone.body["id"] == .string(exam) && undone.body["status"] == .string("ended") && undone.body["answeredCount"] == .number(3))
        #expect(try snapshot(world) == before)
        #expect(try await world.setup().body["exams"]?.arrayValue?.count == 1)
        #expect(words(try await world.harness.send("POST", "/api/exams/\(exam)/undo-delete")) == "409 not_deleted That exam is not deleted.")
        // The same preview reads the same confirm: it is what the exam is, not when it was looked at.
        #expect(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body["confirm"]?.stringValue == confirm)
    }

    @Test func undoLastsThirtyDays() async throws {
        let (world, exam, _) = try await world()
        let confirm = try #require(try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body["confirm"]?.stringValue)
        _ = try await delete(world, exam, confirm: confirm)
        let day = 24.0 * 60 * 60
        world.at(40 + 31 * day)
        #expect(
            words(try await world.harness.send("POST", "/api/exams/\(exam)/undo-delete"))
                == "409 undo_expired This exam was deleted more than 30 days ago, so it can't be brought back.")
        // Nothing is removed on its own: the exam and its answers are still there.
        #expect(try world.count("study_session", "id = '\(exam)'") == 1 && (try world.count("attempt", "study_session_id = '\(exam)'")) == 3)
    }

    // MARK: An exam still going

    @Test func anExamStillGoingIsRefusedUntilItIsFinishedOrItsTimeIsUp() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let exam = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(5)
        let preview = try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body
        #expect(preview["refusal"] == .string("This exam is still going. Finish or leave it, then delete it.") && preview["finishedAt"] == .null)
        let confirm = try #require(preview["confirm"]?.stringValue)
        #expect(words(try await delete(world, exam, confirm: confirm)) == "409 exam_in_progress This exam is still going. Finish or leave it, then delete it.")
        // In its grace it is still going.
        world.at(280)
        #expect(try await delete(world, exam, confirm: confirm).status == 409)
        // Once its time is up it reads as ended: no refusal, and the end it settles on is a timeout at its end time.
        world.at(301)
        let after = try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body
        #expect(after["refusal"] == .null && after["finishedAt"] == .string(world.time(270)))
        #expect(try await delete(world, exam, confirm: try #require(after["confirm"]?.stringValue)).status == 204)
    }

    // MARK: The server's own words

    @Test func theRefusalsAndTheWarningOfAnExamStillGoingAreTheRecordedOnes() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let exam = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(5)
        let preview = try await world.harness.send("GET", "/api/exams/\(exam)/delete-preview").body
        let recorded = try Fixture.load("exam-delete-preview-in-progress").response.body
        for key in ["message", "warning", "refusal", "undoDays", "answeredCount", "changedCount", "unansweredCount", "finishedAt"] { #expect(preview[key] == recorded[key], "\(key)") }
        let refused = try await world.harness.send("DELETE", "/api/exams/\(exam)?confirm=\(try #require(preview["confirm"]?.stringValue))")
        let recordedRefusal = try Fixture.load("exam-delete-in-progress").response
        #expect(refused.status == recordedRefusal.status && refused.body == recordedRefusal.body)
    }
}
