import Foundation
import Testing

@testable import QBankKit

struct BankCombineTests {
    typealias World = CombineWorld

    @Test("ID-1, ID-2, ID-3, ID-4, ID-5 and WIN-2: independent catalogs join in their resolved parent lists")
    func catalogIdentities() async throws {
        let server = try await World.make("cc000000")
        let phone = try await World.make("dd000000")
        try phone.store.run("UPDATE course SET title = 'TOPIC' WHERE kind = 'topic'")
        try phone.store.run("UPDATE course SET code = lower(code) WHERE kind = 'course'")
        try phone.store.run("UPDATE course_exam SET name = upper(name)")
        try phone.store.run("UPDATE folder SET name = upper(name)")
        let (result, ledger) = try phone.combine(into: server)
        for (rule, table) in [("ID-1", "semesters"), ("ID-2", "courses"), ("ID-3", "courses"), ("ID-4", "courseExams"), ("ID-5", "folders")] {
            #expect(ledger.joins.contains { $0.rule == rule && $0.table == table && $0.phoneKey != $0.serverKey })
        }
        #expect(try result.run("SELECT id, course_id, course_exam_id FROM folder").first?.values == [.text(server.folder), .text(server.study.course), .text(server.page)])
        #expect(try result.run("SELECT kind FROM course").count == 2)
        #expect(try result.run("SELECT folder_id FROM practice_set").first?[0] == .text(server.folder))
        #expect(ledger.phone == BankSummary(sets: 1, questions: 2, answers: 0))
        #expect(ledger.phone == ledger.server && ledger.server == ledger.inBoth && ledger.inBoth == ledger.combined)
    }

    @Test("ID-8, ID-10, ID-12, ID-15, ID-16, ID-17, ID-18 and WIN-9 to WIN-11: two imports, clears and answers meet in the server's set")
    func independentImports() async throws {
        let server = try await World.make("cc000000")
        let phone = try await World.make("dd000000")
        try await server.study.answer(0, choice: 1, number: 1)
        _ = try await server.study.harness.send("POST", "/api/courses/\(server.study.course)/review/clear", .object(["confirmed": .bool(true)]))
        phone.study.harness.set(World.date.addingTimeInterval(10))
        try await phone.study.answer(0, choice: 1, number: 2)
        _ = try await phone.study.harness.send("POST", "/api/courses/\(phone.study.course)/review/clear", .object(["confirmed": .bool(true)]))
        phone.study.harness.set(World.date.addingTimeInterval(20))
        try await phone.study.answer(0, choice: 2, number: 3, fromReview: true)
        for (world, course) in [(server, server.topic), (phone, phone.study.course)] {
            _ = try await world.study.harness.send("PUT", "/api/me/place", .object(["courseId": .string(course)]))
        }
        let exam = StudySet.attemptID(77)
        try phone.study.insertExam(id: exam, questions: [1, 0], startedAt: QBankJSON.formatDate(World.date), limit: 300, finished: true)
        let question = phone.study.questions[1]
        let score = #"{"items":[{"questionId":"\#(question)","response":"\#(question)"}],"byFolder":[{"folderId":"\#(phone.folder)"}],"unknown":9007199254740993}"#
        try phone.store.run("UPDATE study_session SET score = ?, seeded_question_ids = question_ids, exam_folder_ids = ? WHERE id = ?", [.text(score), .text("[\"\(phone.folder)\"]"), .text(exam)])

        let (result, ledger) = try phone.combine(into: server)
        let rules = Set(ledger.joins.map(\.rule))
        #expect(Set(["ID-8", "ID-10", "ID-12", "ID-15", "ID-16", "ID-17"]).isSubset(of: rules))
        #expect(try result.run("SELECT id FROM practice_set").first?[0] == .text(server.study.setID))
        #expect(try result.run("SELECT DISTINCT question_id FROM attempt").map(\.values) == [[.text(server.study.questions[0])]])
        #expect(try result.run("SELECT attempts, correct_attempts, in_review FROM question_progress").first?.values == [3, 0, true])
        #expect(try result.run("SELECT cleared_at FROM review_clear") == phone.store.run("SELECT cleared_at FROM review_clear"))
        #expect(try result.run("SELECT course_id FROM study_place").first?[0] == .text(server.study.course))
        let session = try #require(try result.run("SELECT * FROM study_session WHERE id = ?", [.text(exam)]).first)
        for field in ["seeded_question_ids", "question_ids"] {
            #expect(try JSONDecoder().decode([String].self, from: Data(session.string(field).utf8)) == [server.study.questions[1], server.study.questions[0]])
        }
        #expect(session.text("exam_folder_ids") == "[\"\(server.folder)\"]")
        let expectedScore = score.replacingOccurrences(of: "\"questionId\":\"\(question)\"", with: "\"questionId\":\"\(server.study.questions[1])\"")
            .replacingOccurrences(of: phone.folder, with: server.folder)
        #expect(session.text("score") == expectedScore)
        #expect(ledger.combined == BankSummary(sets: 1, questions: 2, answers: 3))
    }

    @Test("ID-8 only joins complete, unambiguous, single-version imports in the same place")
    func incompleteMatchesStaySeparate() async throws {
        let server = try await World.make("cc000000")
        let base = try await World.make("dd000000")
        for edit in [
            "UPDATE question SET content_hash = 'different' WHERE position = 1", "UPDATE question SET position = position + 10",
            "UPDATE term SET key = 'other'", "DELETE FROM term", "UPDATE practice_set SET folder_id = NULL", "UPDATE practice_set SET kind = 'exam'",
            "UPDATE practice_set SET deleted_at = imported_at, deletion_id = id",
        ] {
            let phone = try base.copy()
            try phone.store.run(edit)
            let (result, ledger) = try phone.combine(into: server)
            #expect(try result.run("SELECT id FROM practice_set").count == 2)
            #expect(!ledger.joins.contains { $0.rule == "ID-8" })
        }
    }

    @Test("ID-6, ID-7, ID-9, ID-11, ID-13, ID-14 and WIN-9: replay of the recorded server archive preserves every row")
    func recordedArchiveAndLostUploadResponse() throws {
        var document = try ArchiveWorld.parsed(ArchiveWorld.recording())
        document["stamp"] = World.stamp
        let data = try ArchiveWorld.serialized(document)
        let merged = try BankCombine.combine(phone: data, server: data, at: World.date)
        let original = try ArchiveWorld.empty()
        let result = try ArchiveWorld.empty()
        try BankArchive.read(data, into: original)
        try BankArchive.read(merged.archive, into: result)
        #expect(try ArchiveWorld.dump(result) == ArchiveWorld.dump(original))
        #expect(try result.run("SELECT stamp FROM bank_archive").first?[0] == .text(World.stamp))
        let rules = Set(merged.ledger.joins.map(\.rule))
        #expect(Set(["ID-6", "ID-7", "ID-9", "ID-11", "ID-13", "ID-14"]).isSubset(of: rules))
        #expect(merged.ledger.inBoth == merged.ledger.combined)
        let retried = try BankCombine.combine(phone: data, server: merged.archive, at: World.date)
        #expect(retried.archive == merged.archive)
    }

    @Test("ID-14 and ID-18: an answer replayed under another id keeps its server id, including in Review")
    func replayedAnswer() async throws {
        let server = try await World.make("cc000000")
        let phone = try await World.make("dd000000")
        for world in [server, phone] {
            try await world.study.answer(0, choice: 2, number: 7)
        }
        _ = try await phone.study.harness.send("POST", "/api/courses/\(phone.study.course)/review/clear", .object(["confirmed": .bool(true)]))
        let (store, ledger) = try phone.combine(into: server)
        let id = try #require(try server.store.run("SELECT id FROM attempt").first?[0])
        #expect(try store.run("SELECT id FROM attempt").map(\.values) == [[id]])
        #expect(try store.run("SELECT last_attempt_id FROM review_clear").first?[0] == id)
        #expect(try store.run("SELECT last_attempt_id, in_review FROM question_progress").first?.values == [id, false])
        #expect(ledger.inBoth.answers == 1)
    }

    @Test("WIN-1, WIN-3, WIN-7 and WIN-8: the latest row wins as a unit, ties and immutable values stay with the server")
    func renameAndDelete() async throws {
        let server = try await World.make("cc000000")
        let phone = try server.copy()
        // An inserted phone row can have an explicit time equal to the server's creation fallback.
        try server.store.run("UPDATE folder SET updated_at = NULL")
        try phone.store.run("UPDATE folder SET name = 'Tie', updated_at = created_at")
        #expect(try phone.combine(into: server).0.run("SELECT name FROM folder").first?[0] == "Week")
        try server.store.run("UPDATE folder SET name = 'Cloud', updated_at = ?", [.text(World.later)])
        try phone.store.run("UPDATE folder SET name = 'Phone', deleted_at = ?, deletion_id = id, updated_at = ?, created_at = ?", [.text(World.newest), .text(World.newest), .text(World.newest)])
        let deleted = try phone.combine(into: server).0
        #expect(try deleted.run("SELECT name, deleted_at, deletion_id, updated_at FROM folder").first?.values == ["Phone", .text(World.newest), .text(server.folder), .text(World.newest)])
        #expect(try deleted.run("SELECT created_at FROM folder") == server.store.run("SELECT created_at FROM folder"))
        try phone.store.run("UPDATE folder SET created_at = ?, updated_at = ?", [.text(World.later), .text(World.later)])
        try server.store.run("UPDATE folder SET updated_at = ?", [.text(World.newest)])
        #expect(try phone.combine(into: server).0.run("SELECT name, deleted_at FROM folder").first?.values == ["Cloud", .null])
    }

    @Test("WIN-5: a newer order is kept and new folders follow in their original relative order")
    func folderOrder() async throws {
        let server = try await World.make("cc000000")
        let phone = try server.copy()
        try phone.store.run("UPDATE folder SET sort_order = 7, updated_at = ?", [.text(World.later)])
        try server.store.run(
            "INSERT INTO folder (id, name, course_id, course_exam_id, sort_order, created_at) SELECT ?, 'Server extra', course_id, course_exam_id, 0, created_at FROM folder",
            [.text(StudySet.attemptID(22))])
        for (index, name) in ["Second", "First"].enumerated() {
            try phone.store.run(
                "INSERT INTO folder (id, name, course_id, course_exam_id, sort_order, created_at) SELECT ?, ?, course_id, course_exam_id, ?, created_at FROM folder WHERE id = ?",
                [.text(StudySet.attemptID(index)), .text(name), .integer(Int64(2 - index)), .text(phone.folder)])
        }
        let (store, ledger) = try phone.combine(into: server)
        #expect(try store.run("SELECT name, sort_order FROM folder ORDER BY sort_order").map(\.values) == [["Week", 7], ["Server extra", 8], ["First", 9], ["Second", 10]])
        #expect(ledger.changedInBoth == [.init(table: "folders", id: phone.folder)], "the folder both hold differed; the new ones are only the phone's")
    }

    @Test("WIN-1: the result names every row both banks hold whose fields differed, and only those")
    func changedInBoth() async throws {
        let server = try await World.make("cc000000")
        let phone = try server.copy()
        #expect(try phone.combine(into: server).1.changedInBoth.isEmpty, "two equal banks differ nowhere")
        try phone.store.run("UPDATE course SET title = 'Renamed', updated_at = ? WHERE id = ?", [.text(World.later), .text(phone.topic)])
        try server.store.run("UPDATE folder SET name = 'Renamed in QBank', updated_at = ?", [.text(World.later)])
        let (store, ledger) = try phone.combine(into: server)
        #expect(Set(ledger.changedInBoth.map(\.table)) == ["courses", "folders"])
        #expect(ledger.changedInBoth.contains(.init(table: "courses", id: phone.topic)))
        #expect(try store.run("SELECT title FROM course WHERE id = ?", [.text(phone.topic)]).first?[0] == "Renamed", "the later change was kept")
    }

    @Test("WIN-14: a rename, move, or undelete that takes another live name keeps the server's place and marks")
    func nameKept() async throws {
        let server = try await World.make("cc000000")
        let phone = try server.copy()
        let other = StudySet.attemptID(90)
        try server.store.run(
            "INSERT INTO folder (id, name, course_id, course_exam_id, sort_order, created_at) SELECT ?, 'Taken', course_id, course_exam_id, 2, created_at FROM folder", [.text(other)])
        try phone.store.run("UPDATE folder SET name = 'taken', sort_order = 5, updated_at = ?", [.text(World.later)])
        let (store, ledger) = try phone.combine(into: server)
        #expect(try store.run("SELECT name, sort_order FROM folder WHERE id = ?", [.text(phone.folder)]).first?.values == ["Week", 5])
        #expect(ledger.namesKept == [.init(table: "folders", id: phone.folder)])
        // The original live name is free on the phone. Pair its new folder only after resolving the rename.
        try phone.store.run(
            "INSERT INTO folder (id, name, course_id, course_exam_id, sort_order, created_at) SELECT ?, 'Week', course_id, course_exam_id, 6, created_at FROM folder", [.text(StudySet.attemptID(91))])
        let (again, receipt) = try phone.combine(into: server)
        #expect(try again.run("SELECT id FROM folder").count == 2)
        #expect(receipt.joins.filter { $0.table == "folders" && $0.serverKey == server.folder }.count == 2)
    }
}
