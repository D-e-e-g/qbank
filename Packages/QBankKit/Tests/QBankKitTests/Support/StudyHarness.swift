import Foundation
import Testing

@testable import QBankKit

/// What the study tests share: a course with one set of single-answer questions, and a way to answer them.
/// Question `Q1` is right at choice 0, `Q2` at choice 1, `Q3` at choice 2, `Q4` at choice 0 again, and so on.
struct StudySet {
    let harness: LocalBankHarness
    let course: String
    let setID: String
    /// The questions' ids, in the set's order.
    let questions: [String]

    static func make(questions count: Int = 3, title: String = "Invented Study", in harness: LocalBankHarness? = nil) async throws -> StudySet {
        let harness = try harness ?? LocalBankHarness()
        let course = try await harness.makeCourse()
        return try await add(title: title, questions: count, to: course, harness: harness)
    }

    static func add(title: String, questions count: Int, to course: String, harness: LocalBankHarness, prefix: String = "Q") async throws -> StudySet {
        let file = Files.make(title, (1...count).map { Files.single("\(prefix)\($0)", right: ($0 - 1) % 3) })
        let imported = try await harness.importFile(file, into: course)
        let setID = try #require(imported.body["setId"]?.stringValue)
        let read = try await harness.send("GET", "/api/practice-sets/\(setID)")
        let ids = try #require(read.body["questions"]?.arrayValue).compactMap { $0["id"]?.stringValue }
        #expect(ids.count == count)
        return StudySet(harness: harness, course: course, setID: setID, questions: ids)
    }

    /// A client id for the nth answer.
    static func attemptID(_ number: Int) -> String { String(format: "aaaaaaaa-0000-4000-8000-%012d", number) }

    /// Answers a single-answer question with `choice`.
    @discardableResult
    func answer(
        _ question: Int, choice: Int, number: Int, guessed: Bool = false, session: String? = nil, fromReview: Bool = false, shuffle: JSONValue? = nil
    ) async throws -> (status: Int, body: JSONValue) {
        var body: [String: JSONValue] = [
            "clientAttemptId": .string(Self.attemptID(number)), "questionId": .string(questions[question]),
            "response": .object(["type": .string("single"), "choice": .number(Double(choice))]), "guessed": .bool(guessed),
        ]
        if let session { body["studySessionId"] = .string(session) }
        if fromReview { body["fromReview"] = .bool(true) }
        if let shuffle { body["shuffle"] = shuffle }
        return try await harness.send("POST", "/api/attempts", .object(body))
    }

    func read() async throws -> JSONValue { try await harness.send("GET", "/api/practice-sets/\(setID)").body }

    func count(_ table: String, _ condition: String = "1 = 1") throws -> Int {
        try harness.store.run("SELECT count(*) AS n FROM \(table) WHERE \(condition)")[0].int("n") ?? 0
    }

    /// An exam row of a given length, written straight to the store, for a test of answers that needs no Start.
    func insertExam(id: String, questions: [Int], startedAt: String, limit: Int, finished: Bool = false) throws {
        let ids = JS.stringify(.array(questions.map { JSNode.string(self.questions[$0]) }))
        try harness.store.run(
            """
            INSERT INTO study_session (id, course_id, mode, set_id, question_ids, started_at, finished_at, end_reason, time_limit_seconds, exam_pool)
            VALUES (?, ?, 'exam', NULL, ?, ?, ?, ?, ?, 'all')
            """,
            [.text(id), .text(course), .text(ids), .text(startedAt), finished ? .text(startedAt) : .null, finished ? .text("finished") : .null, .integer(Int64(limit))])
    }

    func progress(_ question: Int) throws -> StoreRow? {
        try harness.store.run(
            "SELECT qp.* FROM question_progress qp JOIN question q ON q.lineage_id = qp.question_lineage_id WHERE q.id = ?", [.text(questions[question])]
        ).first
    }
}

/// "404 code message" for an answer, for one comparison with the server's words.
func words(_ answer: (status: Int, body: JSONValue)) -> String {
    "\(answer.status) \(answer.body["error"]?.stringValue ?? "") \(answer.body["message"]?.stringValue ?? "")"
}
