import Foundation

@testable import QBankKit

/// Rows and folders for the store's tests, with invented data only.
enum StoreFixtures {
    static let time = "2026-11-22T10:00:00.000Z"

    /// A lowercase UUID that is the same for the same number.
    static func id(_ number: Int) -> StoreValue {
        .text(String(format: "00000000-0000-4000-8000-%012x", number))
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QBankStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    static func insertSemester(_ transaction: StoreTransaction, _ number: Int = 1) throws {
        try transaction.execute(
            "INSERT INTO semester (id, number, name, created_at) VALUES (?, ?, ?, ?)",
            [id(number), .integer(Int64(number)), .text("Semester \(number)"), .text(time)])
    }

    static func insertCourse(_ transaction: StoreTransaction, _ number: Int, semester: Int? = nil) throws {
        try transaction.execute(
            "INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)",
            [id(number), semester.map(id) ?? .null, .text(semester == nil ? "topic" : "course"), .text(semester == nil ? "" : "N100"), .text("Course \(number)"), .text(time)])
    }

    /// A course with one practice set holding one question, and one answer to it.
    static func insertStudiedCourse(_ transaction: StoreTransaction) throws {
        try insertSemester(transaction)
        try insertCourse(transaction, 10, semester: 1)
        try transaction.execute(
            """
            INSERT INTO practice_set (id, course_id, lineage_id, title, description, week_label, sort_order, imported_at, file_hash, stats, is_current, kind)
            VALUES (?, ?, ?, 'Set', '', 'Week 1', 1, ?, 'hash', '{}', 1, 'practice')
            """, [id(20), id(10), id(21), .text(time)])
        try transaction.execute(
            """
            INSERT INTO question (id, set_id, lineage_id, public_id, position, type, topic, week_label, stem, ask, body, rationale, takeaway, term_keys, content_hash)
            VALUES (?, ?, ?, 'q1', 1, 'mcq', '', 'Week 1', 'Stem', 'Ask', '{"options":[]}', 'Why', 'Take', '[]', 'hash')
            """, [id(30), id(20), id(31)])
        try transaction.execute(
            """
            INSERT INTO attempt (id, client_attempt_id, question_id, response, status, points, max_points, guessed, answered_at)
            VALUES (?, ?, ?, '{"choice":"a"}', 'correct', 1, 1, 0, ?)
            """, [id(40), id(41), id(30), .text(time)])
    }

    static func count(_ store: LocalStore, _ table: String) throws -> Int {
        try store.read { try $0.value("SELECT count(*) FROM \(table)") }.flatMap { if case .integer(let n) = $0 { Int(n) } else { nil } } ?? -1
    }

    /// The shape of the file: every table, index and its SQL, by name.
    static func shape(_ store: LocalStore) throws -> [String] {
        try store.run("SELECT type || ' ' || name || ': ' || ifnull(sql, '') AS item FROM sqlite_master ORDER BY name").compactMap { $0.text("item") }
    }
}
