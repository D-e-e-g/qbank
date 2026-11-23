import Foundation
import Testing

@testable import QBankKit

/// Recording an answer on the phone: scored once, kept once for each id, counted into progress that a repeat,
/// a retry or a late arrival never lowers. Invented data only.
@Suite struct LocalBankAnswerTests {
    // MARK: Saving once

    @Test func anAnswerIsScoredSavedAndCountedOnce() async throws {
        let study = try await StudySet.make()
        let first = try await study.answer(0, choice: 1, number: 1, shuffle: .object(["kind": .string("options"), "order": .array([.number(2), .number(0), .number(1)])]))
        #expect(first.status == 201)
        #expect(first.body["status"] == .string("incorrect") && first.body["points"] == .number(0) && first.body["maxPoints"] == .number(1))
        #expect(first.body["inReview"] == .bool(true) && first.body["replayed"] == .bool(false) && first.body["label"] == .string("Not correct"))
        #expect(first.body["pointsText"] == .null && first.body["ruleText"] == .null && first.body["courseId"] == .string(study.course))
        #expect(first.body["answeredAt"]?.stringValue == QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)))

        let again = try await study.answer(0, choice: 1, number: 1, shuffle: .object(["order": .array([.number(2), .number(0), .number(1)]), "kind": .string("options")]))
        #expect(again.status == 200 && again.body["replayed"] == .bool(true) && again.body["answeredAt"] == first.body["answeredAt"])
        #expect(try study.count("attempt") == 1)
        let progress = try #require(try study.progress(0))
        #expect(progress.int("attempts") == 1 && progress.int("correct_attempts") == 0 && progress.text("last_status") == "incorrect")
    }

    @Test func anIdSentAgainWithAnotherAnswerIsAConflictAndChangesNothing() async throws {
        let study = try await StudySet.make()
        try await study.answer(0, choice: 1, number: 1)
        let before = try study.harness.rows("SELECT * FROM question_progress")
        let conflict = "409 attempt_conflict That attempt id was already saved with a different answer."
        #expect(words(try await study.answer(0, choice: 0, number: 1)) == conflict)
        #expect(words(try await study.answer(0, choice: 1, number: 1, guessed: true)) == conflict)
        #expect(words(try await study.answer(1, choice: 1, number: 1)) == conflict)
        #expect(words(try await study.answer(0, choice: 1, number: 1, shuffle: .object(["kind": .string("plain")]))) == conflict)
        #expect(try study.harness.rows("SELECT * FROM question_progress") == before)
        #expect(try study.count("attempt") == 1)
    }

    @Test func aRetryOfAnAnswerThatJoinedASittingStillReplays() async throws {
        let study = try await StudySet.make()
        let first = try await study.answer(0, choice: 0, number: 1)
        #expect(try study.count("study_session", "mode = 'practice'") == 1)
        let retry = try await study.answer(0, choice: 0, number: 1)
        #expect(retry.status == 200 && retry.body["replayed"] == .bool(true) && retry.body["answeredAt"] == first.body["answeredAt"])
        #expect(try study.count("study_session") == 1 && study.count("attempt") == 1)
    }

    // MARK: Progress

    @Test func progressAddsEachNewAnswerAndTheLatestDecidesReview() async throws {
        let study = try await StudySet.make()
        try await study.answer(0, choice: 2, number: 1)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_100))
        let right = try await study.answer(0, choice: 0, number: 2)
        #expect(right.body["status"] == .string("correct") && right.body["inReview"] == .bool(false) && right.body["label"] == .string("Correct"))
        var progress = try #require(try study.progress(0))
        #expect(progress.int("attempts") == 2 && progress.int("correct_attempts") == 1 && progress.text("last_status") == "correct" && progress.bool("in_review") == false)
        #expect(progress.text("last_attempt_id") != nil && progress.int("last_points") == 1)

        study.harness.set(Date(timeIntervalSince1970: 1_700_000_200))
        let guessed = try await study.answer(0, choice: 0, number: 3, guessed: true)
        #expect(guessed.body["status"] == .string("correct") && guessed.body["inReview"] == .bool(true))
        progress = try #require(try study.progress(0))
        #expect(progress.int("attempts") == 3 && progress.int("correct_attempts") == 2 && progress.bool("last_guessed") == true && progress.bool("in_review") == true)
    }

    @Test func anAnswerThatIsNotLaterNeverTakesOverWhatWasAnsweredLast() async throws {
        let study = try await StudySet.make()
        // Both are stamped with the same time; the one with the smaller attempt id is not later.
        let later = LocalBank(store: study.harness.store, clock: { Date(timeIntervalSince1970: 1_700_000_000) }, ids: { "ffffffff-0000-4000-8000-000000000001" })
        let earlier = LocalBank(store: study.harness.store, clock: { Date(timeIntervalSince1970: 1_700_000_000) }, ids: { "00000000-0000-4000-8000-000000000001" })
        func send(_ bank: LocalBank, _ number: Int, choice: Int) async throws -> Int {
            var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid/api/attempts")))
            request.httpMethod = "POST"
            let body: JSONValue = .object([
                "clientAttemptId": .string(StudySet.attemptID(number)), "questionId": .string(study.questions[0]),
                "response": .object(["type": .string("single"), "choice": .number(Double(choice))]), "guessed": .bool(false),
            ])
            request.httpBody = try JSONEncoder().encode(body)
            return try await bank.send(request).1.statusCode
        }
        #expect(try await send(later, 1, choice: 1) == 201)
        #expect(try await send(earlier, 2, choice: 0) == 201)
        let progress = try #require(try study.progress(0))
        #expect(progress.int("attempts") == 2 && progress.int("correct_attempts") == 1)
        #expect(progress.text("last_status") == "incorrect" && progress.text("last_attempt_id") == "ffffffff-0000-4000-8000-000000000001" && progress.bool("in_review") == true)
    }

    @Test func theAnswerIsKeptWithTheCourseUsedLast() async throws {
        let study = try await StudySet.make()
        #expect(try await study.harness.send("GET", "/api/me/place").body["courseId"] == .null)
        try await study.answer(0, choice: 0, number: 1)
        #expect(try await study.harness.send("GET", "/api/me/place").body["courseId"] == .string(study.course))
    }

    // MARK: Refusals, in the server's words

    @Test func eachRefusalIsInTheServersWords() async throws {
        let study = try await StudySet.make()
        func send(_ patch: [String: JSONValue?]) async throws -> String {
            var body: [String: JSONValue] = [
                "clientAttemptId": .string(StudySet.attemptID(1)), "questionId": .string(study.questions[0]),
                "response": .object(["type": .string("single"), "choice": .number(0)]), "guessed": .bool(false),
            ]
            for (key, value) in patch { body[key] = value }
            for (key, value) in patch where value == nil { body[key] = nil }
            return words(try await study.harness.send("POST", "/api/attempts", .object(body)))
        }
        let invalid = "400 invalid_request Check the fields and try again."
        #expect(try await send(["clientAttemptId": .string("nope")]) == invalid)
        #expect(try await send(["questionId": .string("")]) == invalid)
        #expect(try await send(["guessed": .string("yes")]) == invalid)
        #expect(try await send(["studySessionId": .null]) == invalid)
        #expect(try await send(["fromReview": .number(1)]) == invalid)
        #expect(try await send(["questionId": .string("00000000-0000-4000-8000-000000000000")]) == "404 question_not_found That question is not in the bank.")
        #expect(try await send(["questionId": .string("not an id")]) == "404 question_not_found That question is not in the bank.")
        #expect(try await send(["response": .null]) == "400 invalid_response Send the answer.")
        #expect(try await send(["response": .number(3)]) == "400 invalid_response Send the answer.")
        #expect(try await send(["response": nil]) == "400 invalid_response Send the answer.")
        #expect(try await send(["response": .object(["type": .string("sata"), "picks": .array([.number(0)])])]) == "400 invalid_response Cannot score a single question with a sata answer.")
        #expect(try await send(["response": .object(["choice": .number(0)])]) == "400 invalid_response Cannot score a single question with a undefined answer.")
        #expect(try await send(["response": .object(["type": .number(4)])]) == "400 invalid_response Cannot score a single question with a 4 answer.")
        let mismatch = "400 invalid_response That answer does not match this question."
        #expect(try await send(["response": .object(["type": .string("single"), "choice": .string("0")])]) == mismatch)
        #expect(try await send(["response": .object(["type": .string("single"), "choice": .number(0.5)])]) == mismatch)
        #expect(try await send(["response": .object(["type": .string("single")])]) == mismatch)
        #expect(try study.count("attempt") == 0 && (try study.count("question_progress")) == 0)
        // An index out of range is a well formed answer that scores as wrong.
        #expect(try await send(["response": .object(["type": .string("single"), "choice": .number(9)])]).hasPrefix("201"))
        #expect(try study.count("attempt") == 1)
    }

    @Test func everyFormatIsScoredByItsRule() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let sata = JSONValue.object([
            "id": .string("S1"), "type": .string("sata"), "ask": .string("Pick."),
            "options": .array([.object(["t": .string("a"), "ok": .bool(true)]), .object(["t": .string("b")]), .object(["t": .string("c"), "ok": .bool(true)])]),
        ])
        let imported = try await harness.importFile(Files.make("Formats", [sata]), into: course)
        let set = try await harness.send("GET", "/api/practice-sets/\(try #require(imported.body["setId"]?.stringValue))")
        let question = try #require(set.body["questions"]?.arrayValue?.first?["id"]?.stringValue)
        func send(_ number: Int, _ picks: [Double]) async throws -> JSONValue {
            try await harness.send(
                "POST", "/api/attempts",
                .object([
                    "clientAttemptId": .string(StudySet.attemptID(number)), "questionId": .string(question),
                    "response": .object(["type": .string("sata"), "picks": .array(picks.map(JSONValue.number))]),
                ])
            ).body
        }
        let partial = try await send(1, [0, 1])
        #expect(partial["status"] == .string("incorrect") && partial["points"] == .number(0) && partial["maxPoints"] == .number(2))
        #expect(partial["pointsText"] == .string("0 of 2 points") && partial["ruleText"] == .string("+1 for each correct choice, -1 for each wrong one"))
        let repeated = try await send(2, [0, 0, 2])
        #expect(repeated["status"] == .string("correct") && repeated["points"] == .number(2) && repeated["label"] == .string("Correct"))
        let half = try await send(3, [0])
        #expect(half["status"] == .string("partial") && half["label"] == .string("Partly correct") && half["inReview"] == .bool(true))
    }

    // MARK: Exams

    @Test func anExamAnswerIsTakenWhileTheExamIsOpenOnceForEachQuestion() async throws {
        let study = try await StudySet.make()
        let running = "e0000000-0000-4000-8000-000000000001"
        try study.insertExam(id: running, questions: [0, 1], startedAt: QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)), limit: 600)
        let saved = try await study.answer(0, choice: 0, number: 1, session: running)
        #expect(saved.status == 201 && saved.body["status"] == .string("correct"))
        #expect(try study.count("attempt", "study_session_id = '\(running)'") == 1 && (try study.count("study_session", "mode = 'practice'")) == 0)
        #expect(words(try await study.answer(0, choice: 0, number: 2, session: running)) == "409 already_answered That question was already answered on this exam.")
        #expect(words(try await study.answer(2, choice: 0, number: 3, session: running)) == "400 question_not_in_exam That question is not on this exam.")
        #expect(words(try await study.answer(1, choice: 0, number: 4, session: "e0000000-0000-4000-8000-0000000000ff")) == "404 exam_not_found That exam is not in the app.")
        // The same id sent again returns the saved answer, with its exam named again.
        #expect(try await study.answer(0, choice: 0, number: 1, session: running).status == 200)
        // Past the time and its grace it takes nothing more; within the grace it still does.
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_000 + 600 + 29))
        #expect(try await study.answer(1, choice: 1, number: 5, session: running).status == 201)
        let over = "e0000000-0000-4000-8000-000000000002"
        try study.insertExam(id: over, questions: [2], startedAt: QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)), limit: 10)
        study.harness.set(Date(timeIntervalSince1970: 1_700_000_000 + 10 + 31))
        #expect(words(try await study.answer(2, choice: 2, number: 6, session: over)) == "409 exam_finished This exam has ended. That answer was not saved.")
        let ended = "e0000000-0000-4000-8000-000000000003"
        try study.insertExam(id: ended, questions: [2], startedAt: QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)), limit: 6000, finished: true)
        #expect(words(try await study.answer(2, choice: 2, number: 7, session: ended)) == "409 exam_finished This exam has ended. That answer was not saved.")
    }

    @Test func aQuestionOfAnExamBankIsAnsweredOnlyOnAnExamAndNeverEntersReview() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let imported = try await harness.importFile(Files.make("Bank", [Files.single("B1")], kind: "exam"), into: course)
        let set = try await harness.send("GET", "/api/practice-sets/\(try #require(imported.body["setId"]?.stringValue))")
        let question = try #require(set.body["questions"]?.arrayValue?.first?["id"]?.stringValue)
        let study = StudySet(harness: harness, course: course, setID: try #require(imported.body["setId"]?.stringValue), questions: [question])
        #expect(words(try await study.answer(0, choice: 1, number: 1)) == "400 exam_only That question is only asked on exams.")
        let id = "e0000000-0000-4000-8000-000000000001"
        try study.insertExam(id: id, questions: [0], startedAt: QBankJSON.formatDate(Date(timeIntervalSince1970: 1_700_000_000)), limit: 600)
        let saved = try await study.answer(0, choice: 1, number: 2, session: id)
        #expect(saved.status == 201 && saved.body["status"] == .string("incorrect") && saved.body["inReview"] == .bool(false))
        #expect(try #require(try study.progress(0)).bool("in_review") == false)
        #expect(try await study.answer(0, choice: 1, number: 2, session: id).body["inReview"] == .bool(false))
    }
}
