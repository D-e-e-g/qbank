import Foundation
import Testing

@testable import QBankKit

/// The tables of `docs/on-phone-bank.md`: each rule the file enforces on its own.
@Suite("The phone's store: tables")
struct LocalStoreSchemaTests {
    typealias Fixtures = StoreFixtures

    /// Runs `body` in a transaction and expects the file to refuse it with a constraint error.
    func refuses(_ store: LocalStore, _ message: String = "", _ body: (StoreTransaction) throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: StoreError.self, "\(message)", sourceLocation: sourceLocation) { try store.transaction(body) }
    }

    @Test func tablesHaveTheServersColumnsWithoutTheOwnerColumns() throws {
        let store = try LocalStore.inMemory()
        func columns(_ table: String) throws -> [String] {
            try store.run("SELECT name FROM pragma_table_info('\(table)') ORDER BY cid").compactMap { $0.text("name") }
        }
        #expect(try columns("semester") == ["id", "number", "name", "starts_on", "ends_on", "archived_at", "created_at"])
        #expect(try columns("course") == ["id", "semester_id", "kind", "code", "title", "sort_order", "archived_at", "created_at", "deleted_at", "deletion_id"])
        #expect(try columns("course_exam") == ["id", "course_id", "name", "sort_order", "link_url", "badge", "created_at", "deleted_at", "deletion_id"])
        #expect(try columns("folder") == ["id", "course_id", "name", "course_exam_id", "sort_order", "created_at", "deleted_at", "deletion_id"])
        #expect(
            try columns("practice_set") == [
                "id", "course_id", "lineage_id", "title", "description", "week_label", "folder_id", "sort_order", "imported_at", "file_hash", "stats", "is_current",
                "replaced_at", "kind", "deleted_at", "deletion_id",
            ])
        #expect(
            try columns("question") == [
                "id", "set_id", "lineage_id", "public_id", "position", "type", "topic", "cj", "client_need", "difficulty", "week_label", "stem", "ask", "body",
                "rationale", "takeaway", "term_keys", "source", "content_hash", "twin_of", "twin_of_lineage_id",
            ])
        #expect(try columns("term") == ["id", "set_id", "key", "term", "meaning"])
        #expect(
            try columns("study_session") == [
                "id", "course_id", "mode", "set_id", "question_ids", "exam_weeks", "exam_folder_ids", "time_limit_seconds", "started_at", "finished_at", "score",
                "end_reason", "exam_pool", "exam_practice_weeks", "seeded_question_ids", "deleted_at", "deletion_id",
            ])
        #expect(
            try columns("attempt") == [
                "id", "client_attempt_id", "study_session_id", "question_id", "response", "shuffle", "status", "points", "max_points", "guessed", "answered_at",
            ])
        #expect(
            try columns("question_progress") == [
                "question_lineage_id", "attempts", "correct_attempts", "last_status", "last_guessed", "last_answered_at", "last_points", "last_max_points", "in_review",
                "last_attempt_id",
            ])
        #expect(try columns("review_clear") == ["question_lineage_id", "last_attempt_id", "cleared_at"])
        #expect(try columns("study_place") == ["course_id", "updated_at"])
    }

    @Test func aWholeStudiedBankFitsAndForeignKeysHold() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { transaction in
            try Fixtures.insertStudiedCourse(transaction)
            try transaction.execute(
                """
                INSERT INTO question_progress (question_lineage_id, attempts, correct_attempts, last_status, last_guessed, last_answered_at, last_points, last_max_points, in_review, last_attempt_id)
                VALUES (?, 1, 1, 'correct', 0, ?, 1, 1, 0, ?)
                """, [Fixtures.id(31), .text(Fixtures.time), Fixtures.id(40)])
            try transaction.execute("INSERT INTO review_clear (question_lineage_id, last_attempt_id, cleared_at) VALUES (?, ?, ?)", [Fixtures.id(31), Fixtures.id(40), .text(Fixtures.time)])
            try transaction.execute("INSERT INTO study_place (course_id, updated_at) VALUES (?, ?)", [Fixtures.id(10), .text(Fixtures.time)])
        }
        #expect(try Fixtures.count(store, "study_place") == 1)
        // A row cannot name a parent that is not there, and a parent cannot go while a row names it.
        refuses(store, "orphan question") { try $0.execute("UPDATE question SET set_id = ?", [Fixtures.id(99)]) }
        refuses(store, "parent with children") { try $0.execute("DELETE FROM practice_set") }
        refuses(store, "attempt of nothing") { try $0.execute("UPDATE attempt SET question_id = ?", [Fixtures.id(99)]) }
    }

    @Test func idsAreLowercaseUUIDsAndTimesHaveTheAPIsForm() throws {
        let store = try LocalStore.inMemory()
        func semester(id: String = "00000000-0000-4000-8000-000000000001", time: String = Fixtures.time, startsOn: String? = nil) -> (StoreTransaction) throws -> Void {
            { try $0.execute("INSERT INTO semester (id, number, name, starts_on, created_at) VALUES (?, 1, 'S', ?, ?)", [.text(id), .optional(startsOn), .text(time)]) }
        }
        refuses(store, "uppercase uuid", semester(id: "00000000-0000-4000-8000-00000000000A"))
        refuses(store, "no dashes", semester(id: "00000000000040008000000000000001"))
        refuses(store, "not hex", semester(id: "0000000g-0000-4000-8000-000000000001"))
        refuses(store, "no milliseconds", semester(time: "2026-11-22T10:00:00Z"))
        refuses(store, "offset instead of Z", semester(time: "2026-11-22T10:00:00.000+00:00"))
        refuses(store, "space instead of T", semester(time: "2026-11-22 10:00:00.000Z"))
        refuses(store, "month 13", semester(time: "2026-13-22T10:00:00.000Z"))
        refuses(store, "date with a time", semester(startsOn: "2026-09-01T00:00:00.000Z"))
        refuses(store, "slashes", semester(startsOn: "2026/09/01"))
        try store.transaction(semester(startsOn: "2026-09-01"))
        #expect(try Fixtures.count(store, "semester") == 1)
    }

    @Test func semestersAreNumberedOneToThreeEachOnce() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertSemester($0, 1) }
        refuses(store, "number 4") { try Fixtures.insertSemester($0, 4) }
        refuses(store, "number 0") { try Fixtures.insertSemester($0, 0) }
        refuses(store, "number twice") {
            try $0.execute("INSERT INTO semester (id, number, name, created_at) VALUES (?, 1, 'Again', ?)", [Fixtures.id(50), .text(Fixtures.time)])
        }
        try store.transaction { try Fixtures.insertSemester($0, 3) }
    }

    @Test func aCourseHasASemesterExactlyWhenItsKindIsCourse() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertSemester($0) }
        func insert(kind: String, semester: StoreValue) -> (StoreTransaction) throws -> Void {
            { try $0.execute("INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, ?, ?, '', 'T', 1, ?)", [Fixtures.id(60), semester, .text(kind), .text(Fixtures.time)]) }
        }
        refuses(store, "course without a semester", insert(kind: "course", semester: .null))
        refuses(store, "topic with a semester", insert(kind: "topic", semester: Fixtures.id(1)))
        refuses(store, "other kind", insert(kind: "lecture", semester: Fixtures.id(1)))
        try store.transaction(insert(kind: "course", semester: Fixtures.id(1)))
    }

    @Test func aDeleteMarksBothColumnsOrNeither() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertSemester($0) }
        func insert(deletedAt: StoreValue, deletionId: StoreValue) -> (StoreTransaction) throws -> Void {
            { try $0.execute("INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at, deleted_at, deletion_id) VALUES (?, ?, 'course', 'C', 'T', 1, ?, ?, ?)", [Fixtures.id(70), Fixtures.id(1), .text(Fixtures.time), deletedAt, deletionId]) }
        }
        refuses(store, "only the time", insert(deletedAt: .text(Fixtures.time), deletionId: .null))
        refuses(store, "only the id", insert(deletedAt: .null, deletionId: Fixtures.id(71)))
        try store.transaction(insert(deletedAt: .text(Fixtures.time), deletionId: Fixtures.id(71)))
    }

    @Test func aFolderNameIsUniqueInItsListCountingEachDeleteApart() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { transaction in
            try Fixtures.insertSemester(transaction)
            try Fixtures.insertCourse(transaction, 10, semester: 1)
            try transaction.execute("INSERT INTO course_exam (id, course_id, name, sort_order, created_at) VALUES (?, ?, 'Exam 1', 1, ?)", [Fixtures.id(80), Fixtures.id(10), .text(Fixtures.time)])
        }
        func folder(_ number: Int, name: String = "Week 1", page: StoreValue = .null, deletion: StoreValue = .null) -> (StoreTransaction) throws -> Void {
            { try $0.execute("INSERT INTO folder (id, course_id, name, course_exam_id, sort_order, created_at, deleted_at, deletion_id) VALUES (?, ?, ?, ?, 1, ?, ?, ?)", [Fixtures.id(number), Fixtures.id(10), .text(name), page, .text(Fixtures.time), deletion == .null ? .null : .text(Fixtures.time), deletion]) }
        }
        try store.transaction(folder(90))
        // Two live folders on no page cannot share a name: nulls are not distinct.
        refuses(store, "same name, no page", folder(91))
        // The same name on a page is another list.
        try store.transaction(folder(92, page: Fixtures.id(80)))
        refuses(store, "same name, same page", folder(93, page: Fixtures.id(80)))
        // A deleted folder no longer holds its name, and each delete is counted apart.
        try store.transaction(folder(94, deletion: Fixtures.id(95)))
        try store.transaction(folder(96, deletion: Fixtures.id(97)))
        refuses(store, "same name, same delete", folder(98, deletion: Fixtures.id(95)))
        // Taking a page away from a folder, by deleting the page, leaves the folder on no page.
        try store.transaction { try $0.execute("UPDATE folder SET name = 'Other' WHERE id = ?", [Fixtures.id(90)]) }
        try store.transaction { try $0.execute("DELETE FROM course_exam WHERE id = ?", [Fixtures.id(80)]) }
        #expect(try store.run("SELECT course_exam_id FROM folder WHERE id = ?", [Fixtures.id(92)]).first?["course_exam_id"] == .null)
    }

    @Test func aTopicTitleIsUniqueIgnoringCaseAmongTopicsThatAreNotDeleted() throws {
        let store = try LocalStore.inMemory()
        func topic(_ number: Int, title: String, deleted: Bool = false) -> (StoreTransaction) throws -> Void {
            { try $0.execute("INSERT INTO course (id, kind, code, title, sort_order, created_at, deleted_at, deletion_id) VALUES (?, 'topic', '', ?, 1, ?, ?, ?)", [Fixtures.id(number), .text(title), .text(Fixtures.time), deleted ? .text(Fixtures.time) : .null, deleted ? Fixtures.id(number + 1000) : .null]) }
        }
        try store.transaction(topic(1, title: "Geography"))
        refuses(store, "same title", topic(2, title: "Geography"))
        refuses(store, "other case", topic(3, title: "geography"))
        try store.transaction(topic(4, title: "Geology"))
        try store.transaction(topic(5, title: "Geography", deleted: true))
        // A course may share a topic's title.
        try store.transaction { transaction in
            try Fixtures.insertSemester(transaction)
            try transaction.execute("INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, ?, 'course', 'G1', 'Geography', 1, ?)", [Fixtures.id(6), Fixtures.id(1), .text(Fixtures.time)])
        }
    }

    @Test func attemptsAreUniqueByTheClientsId() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertStudiedCourse($0) }
        refuses(store, "same client attempt id") {
            try $0.execute("INSERT INTO attempt (id, client_attempt_id, question_id, response, status, points, max_points, guessed, answered_at) VALUES (?, ?, ?, '1', 'correct', 1, 1, 0, ?)", [Fixtures.id(42), Fixtures.id(41), Fixtures.id(30), .text(Fixtures.time)])
        }
    }

    @Test func kindsAndJSONAreChecked() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertStudiedCourse($0) }
        refuses(store, "set kind") { try $0.execute("UPDATE practice_set SET kind = 'quiz'") }
        refuses(store, "bool of 2") { try $0.execute("UPDATE practice_set SET is_current = 2") }
        refuses(store, "stats not json") { try $0.execute("UPDATE practice_set SET stats = 'not json'") }
        refuses(store, "stats a list") { try $0.execute("UPDATE practice_set SET stats = '[]'") }
        refuses(store, "body a list") { try $0.execute("UPDATE question SET body = '[]'") }
        refuses(store, "term keys an object") { try $0.execute("UPDATE question SET term_keys = '{}'") }
        refuses(store, "position 0") { try $0.execute("UPDATE question SET position = 0") }
        refuses(store, "answer status") { try $0.execute("UPDATE attempt SET status = 'wrong'") }
        refuses(store, "response not json") { try $0.execute("UPDATE attempt SET response = '{'") }
        // A response may be any JSON value, a shuffle may be null.
        try store.transaction { try $0.execute("UPDATE attempt SET response = '\"a\"', shuffle = '[2,0,1]'") }
        try store.transaction { try $0.execute("UPDATE attempt SET shuffle = NULL") }
        // Tables are strict: text that is not a number is not stored in an integer column.
        refuses(store, "text in an integer column") { try $0.execute("UPDATE question SET position = 'first'") }
    }

    @Test func aStudySessionHoldsItsModesAndLists() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertStudiedCourse($0) }
        func session(mode: String = "exam", reason: String? = "finished", pool: String = "all", weeks: String? = nil) -> (StoreTransaction) throws -> Void {
            { try $0.execute("INSERT INTO study_session (id, course_id, mode, question_ids, exam_weeks, started_at, end_reason, exam_pool) VALUES (?, ?, ?, '[]', ?, ?, ?, ?)", [Fixtures.id(110), Fixtures.id(10), .text(mode), .optional(weeks), .text(Fixtures.time), .optional(reason), .text(pool)]) }
        }
        refuses(store, "mode", session(mode: "cram"))
        refuses(store, "end reason", session(reason: "quit"))
        refuses(store, "pool", session(pool: "some"))
        refuses(store, "weeks not a list", session(weeks: "{}"))
        try store.transaction(session(reason: nil, weeks: "[\"Week 1\"]"))
    }

    @Test func thereIsAtMostOneStudyPlace() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { transaction in
            try Fixtures.insertSemester(transaction)
            try Fixtures.insertCourse(transaction, 10, semester: 1)
            try Fixtures.insertCourse(transaction, 11, semester: 1)
            try transaction.execute("INSERT INTO study_place (course_id, updated_at) VALUES (?, ?)", [Fixtures.id(10), .text(Fixtures.time)])
        }
        refuses(store, "second place") { try $0.execute("INSERT INTO study_place (course_id, updated_at) VALUES (?, ?)", [Fixtures.id(11), .text(Fixtures.time)]) }
        try store.transaction { try $0.execute("UPDATE study_place SET course_id = ?", [Fixtures.id(11)]) }
        #expect(try Fixtures.count(store, "study_place") == 1)
    }
}
