import Foundation
import Testing

@testable import QBankKit

/// What the exam tests share: a bank with one course and sets in folders of their own, a way to start,
/// answer and read exams, and a clock the test moves. Invented data only.
struct ExamWorld {
    /// The instant every test starts at.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    let harness: LocalBankHarness
    let course: String
    /// The ids of the folders made so far, by name.
    private(set) var folders: [String: String] = [:]
    /// Each folder's practice questions, in order.
    private(set) var questions: [String: [String]] = [:]
    private var attempts = 0

    static func make() async throws -> ExamWorld {
        let harness = try LocalBankHarness()
        harness.set(epoch)
        return ExamWorld(harness: harness, course: try await harness.makeCourse())
    }

    /// A folder named `name` holding one practice set of `count` single-answer questions. Question n is right at choice n % 3.
    @discardableResult
    mutating func addFolder(_ name: String, questions count: Int = 3, kind: String? = nil, twins: [String]? = nil) async throws -> [String] {
        let questions = (1...count).map { number in
            Files.single("\(name)-\(number)", right: (number - 1) % 3, extra: twins.map { ["twinOf": .string($0[number - 1])] } ?? [:])
        }
        let file = Files.make("\(name) set", questions, kind: kind)
        let id: String
        if let known = folders[name] {
            id = known
            let imported = try await harness.importFile(file, into: course, folder: .string(id))
            #expect(imported.status == 201, "\(imported.body)")
            return try await ids(of: imported)
        }
        let imported = try await harness.importFile(file, into: course, folderName: name)
        #expect(imported.status == 201, "\(imported.body)")
        let course = try await harness.send("GET", "/api/courses/\(self.course)")
        id = try #require(course.body["folders"]?.arrayValue?.first { $0["name"]?.stringValue == name }?["id"]?.stringValue)
        folders[name] = id
        let found = try await ids(of: imported)
        if kind == nil { self.questions[name] = found }
        return found
    }

    private func ids(of imported: (status: Int, body: JSONValue)) async throws -> [String] {
        let set = try await harness.send("GET", "/api/practice-sets/\(try #require(imported.body["setId"]?.stringValue))")
        return try #require(set.body["questions"]?.arrayValue).compactMap { $0["id"]?.stringValue }
    }

    /// The time, `seconds` after the epoch.
    func at(_ seconds: Double) { harness.set(Self.epoch.addingTimeInterval(seconds)) }

    func time(_ seconds: Double) -> String { QBankJSON.formatDate(Self.epoch.addingTimeInterval(seconds)) }

    // MARK: Requests

    func setup(_ query: String = "") async throws -> (status: Int, body: JSONValue) {
        try await harness.send("GET", "/api/courses/\(course)/exams\(query)")
    }

    func start(
        _ names: [String], pool: String = "all", replaces: JSONValue? = .null, extra: [String: JSONValue] = [:]
    ) async throws -> (status: Int, body: JSONValue) {
        var body: [String: JSONValue] = ["folderIds": .array(names.map { .string(folders[$0] ?? $0) }), "pool": .string(pool)]
        if let replaces { body["replaces"] = replaces }
        for (key, value) in extra { body[key] = value }
        return try await harness.send("POST", "/api/courses/\(course)/exams", .object(body))
    }

    func read(_ exam: String) async throws -> (status: Int, body: JSONValue) { try await harness.send("GET", "/api/exams/\(exam)") }

    func finish(_ exam: String, _ reason: String = "finished") async throws -> (status: Int, body: JSONValue) {
        try await harness.send("POST", "/api/exams/\(exam)/finish", .object(["reason": .string(reason)]))
    }

    /// Answers a question of an exam with choice `choice`.
    @discardableResult
    mutating func answer(_ question: String, choice: Int, exam: String? = nil, guessed: Bool = false) async throws -> (status: Int, body: JSONValue) {
        attempts += 1
        var body: [String: JSONValue] = [
            "clientAttemptId": .string(StudySet.attemptID(attempts)), "questionId": .string(question),
            "response": .object(["type": .string("single"), "choice": .number(Double(choice))]), "guessed": .bool(guessed),
        ]
        if let exam { body["studySessionId"] = .string(exam) }
        return try await harness.send("POST", "/api/attempts", .object(body))
    }

    /// The question of an exam as it reads, by the name its file gave it (`Week 1-2`).
    func question(_ exam: JSONValue, _ name: String) throws -> String {
        try #require(exam["questions"]?.arrayValue?.first { $0["publicId"]?.stringValue == name }?["id"]?.stringValue)
    }

    func progress(_ question: String) throws -> StoreRow? {
        try harness.store.run("SELECT qp.* FROM question_progress qp JOIN question q ON q.lineage_id = qp.question_lineage_id WHERE q.id = ?", [.text(question)]).first
    }

    func count(_ table: String, _ condition: String = "1 = 1") throws -> Int {
        try harness.store.run("SELECT count(*) AS n FROM \(table) WHERE \(condition)")[0].int("n") ?? 0
    }
}
