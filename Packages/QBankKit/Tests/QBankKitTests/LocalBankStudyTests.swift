import Foundation
import Testing

@testable import QBankKit

/// A set's sittings and Start over, the course card's counts, the Review list and the course used last, on the phone.
/// Invented data only.
@Suite struct LocalBankStudyTests {
    private func run(_ study: StudySet) async throws -> (run: String?, sitting: JSONValue?) {
        let read = try await study.read()
        return (read["run"]?.stringValue, read["sitting"])
    }

    // MARK: Sittings and the run

    @Test func aSetIsNewUntilAnswered() async throws {
        let study = try await StudySet.make()
        let read = try await study.read()
        #expect(read["run"] == .string("new") && read["sitting"] == .null)
    }

    @Test func theFirstAnswerOpensASittingAndTheSetIsMidwayUntilEveryQuestionIsAnswered() async throws {
        let study = try await StudySet.make()
        try await study.answer(0, choice: 0, number: 1)
        var read = try await study.read()
        #expect(read["run"] == .string("midway"))
        let sitting = try #require(read["sitting"])
        #expect(sitting["id"]?.stringValue != nil && sitting["startedAt"] == .string(QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000))))
        #expect(sitting["answeredQuestionIds"] == .array([.string(study.questions[0])]))
        let answer = try #require(sitting["answers"]?.arrayValue?.first)
        #expect(answer["clientAttemptId"] == .string(StudySet.attemptID(1)) && answer["questionId"] == .string(study.questions[0]) && answer["status"] == .string("correct"))
        #expect(answer["response"] == .object(["type": .string("single"), "choice": .number(0)]) && answer["shuffle"] == .null && answer["label"] == .string("Correct"))

        try await study.answer(1, choice: 1, number: 2)
        read = try await study.read()
        #expect(read["sitting"]?["answeredQuestionIds"]?.arrayValue?.count == 2)
        #expect(try study.count("study_session", "mode = 'practice' AND finished_at IS NULL") == 1)

        try await study.answer(2, choice: 2, number: 3)
        read = try await study.read()
        #expect(read["run"] == .string("done") && read["sitting"] == .null)
        let closed = try study.harness.store.run("SELECT end_reason, finished_at FROM study_session")[0]
        #expect(closed.text("end_reason") == "finished" && closed.text("finished_at") != nil)
    }

    @Test func aFinishedSetOpensARetakeOnlyAtItsFirstQuestion() async throws {
        let study = try await StudySet.make()
        for number in 0..<3 { try await study.answer(number, choice: number, number: number + 1) }
        try await study.answer(1, choice: 1, number: 4)
        #expect(try study.count("study_session") == 1)
        try await study.answer(0, choice: 0, number: 5)
        #expect(try study.count("study_session") == 2 && (try study.count("study_session", "finished_at IS NULL")) == 1)
        #expect(try await run(study).run == "done")
        // The retake's own answers go on counting: nothing is lost by taking it again.
        #expect(try #require(try study.progress(0)).int("attempts") == 2)
    }

    @Test func startOverEndsTheSittingAndKeepsEveryAnswer() async throws {
        let study = try await StudySet.make(questions: 4)
        try await study.answer(0, choice: 0, number: 1)
        try await study.answer(1, choice: 0, number: 2)
        let before = try study.harness.rows("SELECT * FROM question_progress")
        let attempts = try study.count("attempt")
        let ended = try await study.harness.send("POST", "/api/practice-sets/\(study.setID)/start-over")
        #expect(ended.status == 200 && ended.body == .object(["ended": .bool(true)]))
        #expect(try await run(study).run == "restarted")
        #expect(try study.harness.rows("SELECT * FROM question_progress") == before && (try study.count("attempt")) == attempts)
        #expect(try study.harness.store.run("SELECT end_reason FROM study_session")[0].text("end_reason") == "left")
        #expect(try await study.harness.send("POST", "/api/practice-sets/\(study.setID)/start-over").body == .object(["ended": .bool(false)]))

        // An answer to another question than the first does not begin the set again; the first does.
        try await study.answer(2, choice: 2, number: 3)
        #expect(try study.count("study_session", "finished_at IS NULL") == 0)
        try await study.answer(0, choice: 0, number: 4)
        let read = try await study.read()
        #expect(read["run"] == .string("midway") && read["sitting"]?["answeredQuestionIds"]?.arrayValue?.count == 1)
    }

    @Test func answersGivenInReviewOpenNoSittingButTheSetContinuesFromThem() async throws {
        let study = try await StudySet.make()
        try await study.answer(0, choice: 1, number: 1, fromReview: true)
        #expect(try study.count("study_session") == 0)
        let read = try await study.read()
        #expect(read["run"] == .string("midway") && read["sitting"]?["id"] == .null && read["sitting"]?["startedAt"] == .null)
        #expect(read["sitting"]?["answeredQuestionIds"] == .array([.string(study.questions[0])]))
        // Starting over a set with no row yet leaves a closed one, so those answers are not picked up again.
        #expect(try await study.harness.send("POST", "/api/practice-sets/\(study.setID)/start-over").body == .object(["ended": .bool(true)]))
        #expect(try study.harness.store.run("SELECT end_reason, seeded_question_ids FROM study_session")[0].text("end_reason") == "left")
        #expect(try await run(study).run == "restarted")
    }

    @Test func aSetAnsweredOnlyOnAnExamStartsAgainAtTheFirstQuestion() async throws {
        let study = try await StudySet.make()
        let id = "e0000000-0000-4000-8000-000000000001"
        try study.insertExam(id: id, questions: [0], startedAt: QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)), limit: 600)
        try await study.answer(0, choice: 0, number: 1, session: id)
        #expect(try await run(study).run == "restarted")
        try await study.answer(0, choice: 0, number: 2)
        #expect(try await run(study).run == "midway")
    }

    @Test func theCourseReadsEachSetsRunAndSitting() async throws {
        let study = try await StudySet.make()
        func sets() async throws -> [JSONValue] {
            let course = try await study.harness.send("GET", "/api/courses/\(study.course)").body
            return course["folders"]?.arrayValue?.flatMap { $0["sets"]?.arrayValue ?? [] } ?? []
        }
        #expect(try await sets().first?["run"] == .string("new"))
        try await study.answer(0, choice: 0, number: 1)
        let midway = try #require(try await sets().first)
        #expect(midway["run"] == .string("midway") && midway["sitting"] == .object(["answeredCount": .number(1)]) && midway["answeredCount"] == .number(1))
    }

    @Test func startOverRefusesAWrongSetInTheServersWords() async throws {
        let study = try await StudySet.make()
        let missing = "ee000000-0000-4000-8000-000000000777"
        #expect(words(try await study.harness.send("POST", "/api/practice-sets/\(missing)/start-over")) == "404 request_refused That set is not in the app.")
        let bank = try await study.harness.importFile(Files.make("Bank", [Files.single("B1")], kind: "exam"), into: study.course)
        let bankID = try #require(bank.body["setId"]?.stringValue)
        #expect(words(try await study.harness.send("POST", "/api/practice-sets/\(bankID)/start-over")) == "404 request_refused That set is not in the app.")
        let replaced = try await study.harness.importFile(Files.make("Invented Study", [Files.single("Q1")]), into: study.course, decision: "replace")
        #expect(replaced.status == 201)
        #expect(words(try await study.harness.send("POST", "/api/practice-sets/\(study.setID)/start-over")) == "404 request_refused That set is not the current version.")
        #expect(try await study.harness.send("POST", "/api/practice-sets/not-an-id/start-over").body["error"] == .string("invalid_request"))
    }

    // MARK: Course counts

    @Test func theCourseCardCountsAnsweredRightReviewAndPoints() async throws {
        let study = try await StudySet.make()
        try await study.answer(0, choice: 0, number: 1)
        try await study.answer(1, choice: 0, number: 2)
        try await study.answer(2, choice: 2, number: 3, guessed: true)
        func card() async throws -> JSONValue {
            let list = try await study.harness.send("GET", "/api/semesters").body
            return try #require(list["semesters"]?.arrayValue?.first?["courses"]?.arrayValue?.first)
        }
        var counts = try await card()
        #expect(counts["questionCount"] == .number(3) && counts["answeredCount"] == .number(3) && counts["fullyRightCount"] == .number(2))
        #expect(counts["reviewCount"] == .number(2) && counts["points"] == .number(2) && counts["maxPoints"] == .number(3))
        let course = try await study.harness.send("GET", "/api/courses/\(study.course)").body
        #expect(course["reviewCount"] == .number(2) && course["answeredCount"] == .number(3) && course["fullyRightCount"] == .number(2))

        _ = try await study.harness.send("POST", "/api/courses/\(study.course)/review/clear", .object(["confirmed": .bool(true)]))
        counts = try await card()
        #expect(counts["reviewCount"] == .number(0) && counts["answeredCount"] == .number(3) && counts["fullyRightCount"] == .number(2) && counts["points"] == .number(2))
    }

    // MARK: Review

    @Test func theReviewListHoldsWhatWasMissedOrGuessedNewestFirstWithItsCounts() async throws {
        let study = try await StudySet.make(questions: 4)
        try await study.answer(0, choice: 1, number: 1)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_050))
        try await study.answer(1, choice: 1, number: 2, guessed: true)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_100))
        try await study.answer(2, choice: 0, number: 3)
        try await study.answer(3, choice: 1, number: 4)

        let all = try await study.harness.send("GET", "/api/courses/\(study.course)/review").body
        #expect(all["filter"] == .string("all") && all["counts"] == .object(["all": .number(4), "missed": .number(3), "partial": .number(0), "guessed": .number(1)]))
        let questions = try #require(all["questions"]?.arrayValue)
        // Newest first; two answered at the same moment read by topic.
        #expect(questions.map { $0["questionId"]?.stringValue } == [study.questions[2], study.questions[3], study.questions[1], study.questions[0]])
        #expect(questions[0]["status"] == .string("incorrect") && questions[2]["status"] == .string("correct") && questions[2]["guessed"] == .bool(true))
        #expect(questions[0]["topic"] == .string("Q3") && questions[0]["format"] == .string("Single answer") && questions[0]["setTitle"] == .string("Invented Study"))
        #expect(questions[0]["folderName"] == .string("Unsorted") && questions[0]["weekLabel"] == .string("Unsorted") && questions[0]["folderId"]?.stringValue != nil)
        func filtered(_ filter: String) async throws -> [String?] {
            var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid/api/courses/\(study.course)/review?filter=\(filter)")))
            request.httpMethod = "GET"
            let (data, _) = try await study.harness.bank.send(request)
            return try JSONDecoder().decode(JSONValue.self, from: data)["questions"]?.arrayValue?.map { $0["questionId"]?.stringValue } ?? []
        }
        #expect(try await filtered("missed") == [study.questions[2], study.questions[3], study.questions[0]])
        #expect(try await filtered("guessed") == [study.questions[1]])
        #expect(try await filtered("partial") == [])
    }

    @Test func aQuestionLeavesReviewWhenAnsweredRightAndReturnsWhenMissedAgain() async throws {
        let study = try await StudySet.make()
        try await study.answer(0, choice: 1, number: 1)
        func listed() async throws -> Int { try await study.harness.send("GET", "/api/courses/\(study.course)/review").body["counts"]?["all"].flatMap { if case .number(let n) = $0 { Int(n) } else { nil } } ?? -1 }
        #expect(try await listed() == 1)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_010))
        try await study.answer(0, choice: 0, number: 2)
        #expect(try await listed() == 0)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_020))
        try await study.answer(0, choice: 2, number: 3)
        #expect(try await listed() == 1)
    }

    @Test func theReviewReadsTheSetItsLastAnswerWasGivenInOrTheExam() async throws {
        let study = try await StudySet.make()
        let id = "e0000000-0000-4000-8000-000000000001"
        try study.insertExam(id: id, questions: [0], startedAt: QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)), limit: 600)
        try await study.answer(0, choice: 1, number: 1, session: id)
        let list = try await study.harness.send("GET", "/api/courses/\(study.course)/review").body
        #expect(list["questions"]?.arrayValue?.first?["setTitle"] == .string("Exam"))
    }

    @Test func clearingAsksFirstAndTakesOnlyTheListWhileEveryAnswerStays() async throws {
        let study = try await StudySet.make()
        let path = "/api/courses/\(study.course)/review/clear"
        #expect(words(try await study.harness.send("POST", path, .object(["confirmed": .bool(false)]))) == "400 confirmation_required Clear all 0 questions from this course's Review list?")
        try await study.answer(0, choice: 1, number: 1)
        #expect(words(try await study.harness.send("POST", path, .object(["confirmed": .bool(false)]))) == "400 confirmation_required Clear all 1 question from this course's Review list?")
        try await study.answer(1, choice: 2, number: 2)
        let progress = try study.harness.rows("SELECT question_lineage_id, attempts, correct_attempts, last_status, last_attempt_id FROM question_progress ORDER BY 1")
        let attempts = try study.harness.rows("SELECT * FROM attempt")
        #expect(try await study.harness.send("POST", path, .object(["confirmed": .bool(true)])).body == .object(["cleared": .number(2)]))
        #expect(try study.harness.rows("SELECT question_lineage_id, attempts, correct_attempts, last_status, last_attempt_id FROM question_progress ORDER BY 1") == progress)
        #expect(try study.harness.rows("SELECT * FROM attempt") == attempts && (try study.count("review_clear")) == 2 && (try study.count("question_progress", "in_review = 1")) == 0)
        #expect(try await study.harness.send("GET", "/api/courses/\(study.course)/review").body["counts"]?["all"] == .number(0))
        #expect(try await study.harness.send("POST", path, .object(["confirmed": .bool(true)])).body == .object(["cleared": .number(0)]))
        // A repeat of an answer from before the clear does not put the question back; a new answer decides again.
        _ = try await study.answer(0, choice: 1, number: 1)
        #expect(try study.count("question_progress", "in_review = 1") == 0)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_010))
        try await study.answer(0, choice: 1, number: 3)
        #expect(try study.count("question_progress", "in_review = 1") == 1)
        #expect(words(try await study.harness.send("POST", path, .object([:]))) == "400 invalid_request Check the fields and try again.")
    }

    @Test func practicingFromReviewDrawsTheListInANewOrderOrOneQuestion() async throws {
        let study = try await StudySet.make(questions: 3)
        for number in 0..<3 { try await study.answer(number, choice: (number + 1) % 3, number: number + 1) }
        let drawn = LocalBank(store: study.harness.store, clock: { Date(timeIntervalSince1970: 1_700_000_000) }, random: { _ in 0 })
        func get(_ query: String, _ bank: LocalBank) async throws -> (status: Int, body: JSONValue) {
            var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid/api/courses/\(study.course)/review/practice\(query)")))
            request.httpMethod = "GET"
            let (data, response) = try await bank.send(request)
            return (response.statusCode, try JSONDecoder().decode(JSONValue.self, from: data))
        }
        let all = try await get("", drawn)
        #expect(all.body["title"] == .string("Review") && all.body["id"] == .string(study.course) && all.body["courseId"] == .string(study.course))
        #expect(all.body["weekLabel"] == .string("") && all.body["folderId"] == .null && all.body["kind"] == .string("practice") && all.body["run"] == .string("new") && all.body["sitting"] == .null)
        let questions = try #require(all.body["questions"]?.arrayValue)
        // The server's shuffle with every draw at zero: the last swaps with the first, then the second with the first.
        #expect(questions.map { $0["id"]?.stringValue } == [study.questions[1], study.questions[2], study.questions[0]])
        #expect(questions.map { $0["position"] } == [.number(1), .number(2), .number(3)])

        let one = try await get("?question=\(study.questions[1])", drawn)
        #expect(one.body["title"] == .string("Review question") && one.body["questions"]?.arrayValue?.count == 1)
        // One question can be any current question of the course, so a row keeps working after it was answered right elsewhere.
        try await study.answer(1, choice: 1, number: 9)
        #expect(try await get("?question=\(study.questions[1])", drawn).status == 200)
        let missing = try await get("?question=ee000000-0000-4000-8000-000000000777", drawn)
        #expect(words(missing) == "404 question_not_found That question is not in this course.")
        #expect(try await get("?filter=sometimes", drawn).body["error"] == .string("invalid_request"))
        #expect(try await get("?filter=guessed", drawn).body["questions"] == .array([]))
    }

    @Test func aCourseThatIsNotThereIsNotInTheApp() async throws {
        let study = try await StudySet.make()
        let missing = "ee000000-0000-4000-8000-000000000777"
        for (method, path, body) in [
            ("GET", "/api/courses/\(missing)/review", nil), ("GET", "/api/courses/\(missing)/review/practice", nil),
            ("POST", "/api/courses/\(missing)/review/clear", JSONValue.object(["confirmed": .bool(true)])),
        ] {
            #expect(words(try await study.harness.send(method, path, body)) == "404 course_not_found That course is not in the app.")
        }
    }

    // MARK: The course used last

    @Test func theCourseUsedLastIsKeptAndIsNoneOnceArchivedOrDeleted() async throws {
        let study = try await StudySet.make()
        let other = try await study.harness.makeCourse(code: "NURS 102")
        #expect(try await study.harness.send("GET", "/api/me/place").body == .object(["courseId": .null]))
        #expect(try await study.harness.send("PUT", "/api/me/place", .object(["courseId": .string(study.course)])).body == .object(["courseId": .string(study.course)]))
        #expect(try await study.harness.send("PUT", "/api/me/place", .object(["courseId": .string(other)])).status == 200)
        #expect(try await study.harness.send("GET", "/api/me/place").body == .object(["courseId": .string(other)]))
        #expect(try study.count("study_place") == 1)

        try study.harness.store.run("UPDATE course SET archived_at = ? WHERE id = ?", [.text("2026-01-01T00:00:00.000Z"), .text(other)])
        #expect(try await study.harness.send("GET", "/api/me/place").body == .object(["courseId": .null]))
        #expect(words(try await study.harness.send("PUT", "/api/me/place", .object(["courseId": .string(other)]))) == "404 course_not_found That course is not in the app.")
        try study.harness.store.run("UPDATE course SET archived_at = NULL WHERE id = ?", [.text(other)])
        try study.harness.store.run("UPDATE course SET deleted_at = ?, deletion_id = ? WHERE id = ?", [.text("2026-01-01T00:00:00.000Z"), .text("d0000000-0000-4000-8000-000000000001"), .text(other)])
        #expect(try await study.harness.send("GET", "/api/me/place").body == .object(["courseId": .null]))
        #expect(words(try await study.harness.send("PUT", "/api/me/place", .object(["courseId": .string(other)]))) == "404 course_not_found That course is not in the app.")
        #expect(try await study.harness.send("PUT", "/api/me/place", .object(["courseId": .string("nope")])).body["error"] == .string("invalid_request"))
        #expect(try await study.harness.send("PUT", "/api/me/place", .object([:])).body["error"] == .string("invalid_request"))
    }

    // MARK: Nothing is lost

    @Test func studyingNeverDeletesMovesOrRenamesASetAFolderOrAnAnswer() async throws {
        let study = try await StudySet.make()
        let tables = ["course", "folder", "practice_set", "question", "term"]
        let before = try tables.map { try study.harness.rows("SELECT * FROM \($0) ORDER BY 1") }
        try await study.answer(0, choice: 1, number: 1)
        try await study.answer(1, choice: 1, number: 2, guessed: true)
        _ = try await study.harness.send("POST", "/api/practice-sets/\(study.setID)/start-over")
        _ = try await study.harness.send("POST", "/api/courses/\(study.course)/review/clear", .object(["confirmed": .bool(true)]))
        _ = try await study.harness.send("PUT", "/api/me/place", .object(["courseId": .string(study.course)]))
        #expect(try tables.map { try study.harness.rows("SELECT * FROM \($0) ORDER BY 1") } == before)
        #expect(try study.count("attempt") == 2 && (try study.count("question_progress")) == 2)
    }
}
