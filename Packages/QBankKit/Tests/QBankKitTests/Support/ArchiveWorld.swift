import Foundation
import Testing

@testable import QBankKit

/// What the bank archive tests share: a bank with a row in every table, made as the app makes one,
/// and a way to read every table of a store back for an exact comparison. Invented data only.
enum ArchiveWorld {
    /// A bank with a row in every table: a course in a semester, a page and a folder, a set replaced by
    /// a newer version, a set with terms, a topic, answers in a sitting, a past exam, a cleared Review, the
    /// place, and rows a delete has marked.
    static func make() async throws -> LocalBankHarness {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let first = Files.make("Cardiac", [Files.single("Q1"), Files.single("Q2", right: 1)], terms: ["pulse": ["Pulse", "The beat felt at the wrist."]], description: "Invented.")
        let imported = try await harness.importFile(first, into: course, folderName: "Week 1")
        let folder = try #require(imported.body["folderId"])
        _ = try await harness.importFile(Files.make("Cardiac", [Files.single("Q1"), Files.single("Q2", right: 1), Files.single("Q3", right: 2)]), into: course, folder: folder, decision: "replace")
        let second = try await harness.importFile(Files.make("Renal", (1...3).map { Files.single("R\($0)", right: $0 % 3) }), into: course, folder: folder)
        let setID = try #require(second.body["setId"]?.stringValue)
        let page = try await harness.send("POST", "/api/courses/\(course)/course-exams", .object(["name": .string("Exam 1"), "folderIds": .array([folder]), "badge": .string("concept")]))
        #expect(page.status == 201)
        let topic = try await harness.send("POST", "/api/topics", .object(["title": .string("Geography")]))
        #expect(topic.status == 201)
        let topicID = try #require(topic.body["id"]?.stringValue)
        _ = try await harness.importFile(Files.make("Capitals", [Files.single("C1")]), into: topicID)

        let study = StudySet(harness: harness, course: course, setID: setID, questions: try await questionIDs(harness, setID))
        try await study.answer(0, choice: 0, number: 1)
        try await study.answer(1, choice: 0, number: 2, guessed: true)
        try await study.answer(2, choice: 2, number: 3)
        try study.insertExam(id: "e1000000-0000-4000-8000-000000000001", questions: [0, 1], startedAt: "2026-11-22T10:00:00.000Z", limit: 600, finished: true)
        _ = try await harness.send("POST", "/api/courses/\(course)/review/clear", .object(["confirmed": .bool(true)]))
        _ = try await harness.send("PUT", "/api/me/place", .object(["courseId": .string(course)]))

        // What a delete leaves: the rows stay, marked with one delete's id.
        let mark = "d1000000-0000-4000-8000-000000000001"
        try harness.store.run("UPDATE course SET deleted_at = '2026-11-22T11:00:00.000Z', deletion_id = ? WHERE id = ?", [.text(mark), .text(topicID)])
        try harness.store.run("UPDATE practice_set SET deleted_at = '2026-11-22T11:00:00.000Z', deletion_id = ? WHERE course_id = ?", [.text(mark), .text(topicID)])
        return harness
    }

    static func questionIDs(_ harness: LocalBankHarness, _ set: String) async throws -> [String] {
        try #require(try await harness.send("GET", "/api/practice-sets/\(set)").body["questions"]?.arrayValue).compactMap { $0["id"]?.stringValue }
    }

    /// Every row of every table as the store holds it, each table in key order, by archive key.
    static func dump(_ store: LocalStore) throws -> [String: [[StoreValue]]] {
        try store.read { transaction in
            var tables: [String: [[StoreValue]]] = [:]
            for table in BankArchiveTables.all {
                tables[table.key] = try transaction.rows("SELECT * FROM \(table.table) ORDER BY \(table.rowKey.map(table.column(of:)) ?? "1")").map(\.values)
            }
            return tables
        }
    }

    static func recording() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "server-bank", withExtension: "json", subdirectory: "Fixtures/bank-archive"))
        return try Data(contentsOf: url)
    }

    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func empty() throws -> LocalStore { try LocalStore.inMemory() }

    static func isEmpty(_ store: LocalStore) throws -> Bool {
        try BankArchive.counts(of: store).values.values.allSatisfy { $0 == 0 }
    }

    /// A document as JSON objects, to damage and write back.
    static func parsed(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func serialized(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
}
