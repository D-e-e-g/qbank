import Foundation
import Testing

@testable import QBankKit

/// A bank for the delete tests, built through the engine's own routes from invented data: one course
/// with two folders (`Week 1` on the page `Exam 1`, with two practice sets and an exam set, and
/// `Week 2` on no page, with one practice set), some answers, and a topic with one set.
struct DeleteWorld {
    struct Made {
        let setID: String
        let folderID: String
        /// The questions' ids, in the set's order.
        let questions: [String]
    }

    let harness: LocalBankHarness
    let course: String
    let page: String
    let week1: String
    let week2: String
    let heartA: Made
    let heartB: Made
    let heartExam: Made
    let lungs: Made
    let topic: String
    let pharmacology: Made

    /// The tables of a bank, which a delete and its Undo must leave row for row as they were.
    static let tables = [
        "semester", "course", "course_exam", "folder", "practice_set", "question", "term", "study_session", "attempt", "question_progress", "review_clear",
        "study_place",
    ]

    init() async throws {
        let harness = try LocalBankHarness()
        self.harness = harness
        course = try await harness.makeCourse()
        heartA = try await Self.makeSet(harness, course, "Heart A", count: 3, folder: .name("Week 1"))
        heartB = try await Self.makeSet(harness, course, "Heart B", count: 2, folder: .id(heartA.folderID))
        heartExam = try await Self.makeSet(harness, course, "Heart A exam", count: 2, folder: .id(heartA.folderID), kind: "exam")
        lungs = try await Self.makeSet(harness, course, "Lungs", count: 2, folder: .name("Week 2"))
        week1 = heartA.folderID
        week2 = lungs.folderID
        let made = try await harness.send("POST", "/api/courses/\(course)/course-exams", .object(["name": .string("Exam 1"), "folderIds": .array([.string(week1)])]))
        #expect(made.status == 201)
        page = try #require(made.body["id"]?.stringValue)
        let topic = try await harness.send("POST", "/api/topics", .object(["title": .string("Pharmacology")]))
        self.topic = try #require(topic.body["id"]?.stringValue)
        pharmacology = try await Self.makeSet(harness, self.topic, "Drugs", count: 2, folder: .name("First Pass"))
        // Heart A: one right, one wrong, one guessed; Lungs: one right.
        try await answer(heartA.questions[0], choice: 0, number: 1)
        try await answer(heartA.questions[1], choice: 0, number: 2)
        try await answer(heartA.questions[2], choice: 2, number: 3, guessed: true)
        try await answer(lungs.questions[0], choice: 0, number: 4)
        try await answer(pharmacology.questions[0], choice: 0, number: 5)
    }

    enum Place {
        case name(String)
        case id(String)
    }

    static func makeSet(_ harness: LocalBankHarness, _ course: String, _ title: String, count: Int, folder: Place, kind: String? = nil) async throws -> Made {
        let file = Files.make(title, (1...count).map { Files.single("\(title.prefix(1))\($0)", right: ($0 - 1) % 3) }, kind: kind)
        let imported =
            switch folder {
            case .name(let name): try await harness.importFile(file, into: course, folderName: name)
            case .id(let id): try await harness.importFile(file, into: course, folder: .string(id))
            }
        #expect(imported.status == 201, "\(imported.body)")
        let setID = try #require(imported.body["setId"]?.stringValue)
        let read = try await harness.send("GET", "/api/practice-sets/\(setID)")
        return Made(
            setID: setID, folderID: try #require(imported.body["folderId"]?.stringValue),
            questions: try #require(read.body["questions"]?.arrayValue).compactMap { $0["id"]?.stringValue })
    }

    @discardableResult
    func answer(_ question: String, choice: Int, number: Int, guessed: Bool = false, session: String? = nil) async throws -> (status: Int, body: JSONValue) {
        var body: [String: JSONValue] = [
            "clientAttemptId": .string(StudySet.attemptID(number)), "questionId": .string(question),
            "response": .object(["type": .string("single"), "choice": .number(Double(choice))]), "guessed": .bool(guessed),
        ]
        if let session { body["studySessionId"] = .string(session) }
        return try await harness.send("POST", "/api/attempts", .object(body))
    }

    /// An exam row the way an exam leaves it (starting one belongs to the exam family): over these folders, asking these questions.
    func insertExam(_ id: String, folders: [String], questions: [String], startedAt: Date? = nil, limit: Int = 600, finished: Bool = false) throws {
        let start = QBankJSON.formatDate(startedAt ?? Date(timeIntervalSince1970: 1_700_000_000))
        _ = try harness.store.run(
            """
            INSERT INTO study_session (id, course_id, mode, question_ids, exam_folder_ids, started_at, finished_at, end_reason, time_limit_seconds, exam_pool)
            VALUES (?, ?, 'exam', ?, ?, ?, ?, ?, ?, 'all')
            """,
            [
                .text(id), .text(course), .text(JS.stringify(.array(questions.map { JSNode.string($0) }))), .text(JS.stringify(.array(folders.map { JSNode.string($0) }))),
                .text(start), finished ? .text(start) : .null, finished ? .text("finished") : .null, .integer(Int64(limit)),
            ])
    }

    /// Every row of every table, in the order stored.
    func snapshot() throws -> [String: [[StoreValue]]] {
        Dictionary(uniqueKeysWithValues: try Self.tables.map { ($0, try harness.rows("SELECT * FROM \($0) ORDER BY rowid")) })
    }

    func send(_ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> (status: Int, body: JSONValue) { try await harness.send(method, path, body) }

    /// The delete preview of a thing, its `confirm`, and the delete that sends it.
    func confirmedDelete(_ path: String, previewPath: String? = nil) async throws -> (status: Int, body: JSONValue) {
        let preview = try await send("GET", (previewPath ?? path) + "/delete-preview")
        #expect(preview.status == 200, "\(preview.body)")
        return try await send("DELETE", "\(path)?confirm=\(preview.body["confirm"]?.stringValue ?? "")")
    }

    func advance(days: Double) { harness.set(Date(timeIntervalSince1970: 1_700_000_000 + days * 86_400)) }
}
