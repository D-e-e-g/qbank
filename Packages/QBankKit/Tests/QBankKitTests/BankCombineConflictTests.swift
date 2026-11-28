import Foundation
import Testing

@testable import QBankKit

extension BankCombineTests {
    @Test("ID-7, WIN-4 and WIN-6: concurrent replacements keep both branches, share unchanged questions' history and restore the other current")
    func concurrentVersions() async throws {
        let server = try await World.make("cc000000")
        try await server.study.answer(0, choice: 0, number: 1)
        let phone = try server.copy()
        func replace(_ world: World, _ title: String, after seconds: Double) async throws -> String {
            world.study.harness.set(World.date.addingTimeInterval(seconds))
            let file = Files.make("Study", [Files.single("Q1"), Files.single("Q2", ask: title)])
            let imported = try await world.study.harness.importFile(file, into: world.study.course, folder: .string(world.folder), decision: "replace", title: "Study")
            return try #require(imported.body["setId"]?.stringValue)
        }
        let earlier = try await replace(server, "First edit?", after: 10)
        let later = try await replace(phone, "Second edit?", after: 20)
        let newFolder = StudySet.attemptID(99)
        try phone.store.run(
            "INSERT INTO folder (id, course_id, name, sort_order, created_at) SELECT ?, course_id, 'Moved', 1, created_at FROM folder", [.text(newFolder)])
        try phone.store.run("UPDATE practice_set SET folder_id = ?, week_label = 'Moved', updated_at = ?", [.text(newFolder), .text(World.newest)])
        try phone.store.run("UPDATE question SET week_label = 'Moved' WHERE week_label = 'Week'")
        let (store, ledger) = try phone.combine(into: server)
        #expect(try store.run("SELECT id FROM practice_set").count == 3)
        #expect(try store.run("SELECT id FROM practice_set WHERE is_current = 1").map(\.values) == [[.text(later)]])
        #expect(try store.run("SELECT DISTINCT folder_id FROM practice_set").map(\.values) == [[.text(newFolder)]])
        #expect(try store.run("SELECT DISTINCT lineage_id FROM question WHERE public_id = 'Q1'").count == 1)
        #expect(try store.run("SELECT attempts FROM question_progress").first?[0] == 1)
        #expect(ledger.joins.contains { $0.rule == "ID-7" })
        #expect(ledger.combined.sets == 1 && ledger.inBoth.sets == 1)
        // The next Restore goes through the normal app route.
        let restored = try await LocalBankHarness(store: store).send("POST", "/api/practice-sets/\(later)/restore")
        #expect(restored.status == 200)
        #expect(try store.run("SELECT id FROM practice_set WHERE is_current = 1").first?[0] == .text(earlier))
    }

    @Test("WIN-10: an exam deletion rebuilds surviving answers and keeps the last progress row when none count")
    func deleteOnlyExam() async throws {
        let server = try await World.make("cc000000")
        try await server.study.answer(0, choice: 2, number: 4)
        let phone = try server.copy()
        try phone.store.run("UPDATE study_session SET mode = 'exam', deleted_at = ?, deletion_id = id, updated_at = ?", [.text(World.later), .text(World.later)])
        try phone.store.run("DELETE FROM question_progress")
        let (store, _) = try phone.combine(into: server)
        #expect(try store.run("SELECT * FROM question_progress") == server.store.run("SELECT * FROM question_progress"))
        #expect(try store.run("SELECT deleted_at FROM study_session").first?[0] == .text(World.later))
    }

    @Test("WIN-12 and WIN-15: an older finished copy beats a newer unfinished one and advances past the server's clock")
    func finishedSitting() async throws {
        let server = try await World.make("cc000000")
        let id = StudySet.attemptID(30)
        try server.study.insertExam(id: id, questions: [0], startedAt: QBankJSON.formatDate(World.date), limit: 300)
        let phone = try server.copy()
        try server.store.run("UPDATE study_session SET updated_at = ?", [.text(World.newest)])
        try phone.store.run("UPDATE study_session SET finished_at = ?, score = '{\"points\":1}', end_reason = 'finished', updated_at = ?", [.text(World.later), .text(World.later)])
        let (store, _) = try phone.combine(into: server)
        #expect(try store.run("SELECT finished_at, score, end_reason, updated_at FROM study_session").first?.values == [.text(World.later), "{\"points\":1}", "finished", "2027-02-01T00:00:00.001Z"])
        // Reversing the conflict still keeps the finished fields.
        try server.store.run("UPDATE study_session SET updated_at = '2028-01-01T00:00:00.000Z'")
        #expect(try server.combine(into: phone).0.run("SELECT finished_at FROM study_session").first?[0] == .text(World.later))
    }

    @Test("WIN-13: the later open exam survives, and the earlier exam ends as left with its saved score, including during grace")
    func competingExams() async throws {
        let server = try await World.make("cc000000")
        let phone = try server.copy()
        let earlier = StudySet.attemptID(40)
        let later = StudySet.attemptID(41)
        try server.study.insertExam(id: earlier, questions: [0], startedAt: QBankJSON.formatDate(World.date), limit: 60)
        try phone.study.insertExam(id: later, questions: [1], startedAt: QBankJSON.formatDate(World.date.addingTimeInterval(20)), limit: 600)
        for seconds in [30.0, 70.0] {
            let (store, _) = try phone.combine(into: server, at: World.date.addingTimeInterval(seconds))
            #expect(try store.run("SELECT id FROM study_session WHERE finished_at IS NULL").map(\.values) == [[.text(later)]])
            let ended = try #require(try store.run("SELECT * FROM study_session WHERE id = ?", [.text(earlier)]).first)
            #expect(ended.text("end_reason") == "left")
            let score = try JSONDecoder().decode(JSONValue.self, from: Data(ended.string("score").utf8))
            #expect(score["questionCount"] == .number(1))
            #expect(score["answered"] == .number(0))
        }
    }

    @Test("ID-8: repeated imports or a version history make a file match ambiguous")
    func ambiguousFileMatches() async throws {
        let server = try await World.make("cc000000")
        let base = try await World.make("dd000000")
        let file = Files.make("Study", [Files.single("Q1"), Files.single("Q2")], terms: ["key": ["Term", "Meaning"]])
        for decision in ["separate", "replace"] {
            let phone = try base.copy()
            let imported = try await phone.study.harness.importFile(file, into: phone.study.course, folder: .string(phone.folder), decision: decision)
            #expect((200..<300).contains(imported.status))
            let (result, receipt) = try phone.combine(into: server)
            #expect(try result.run("SELECT id FROM practice_set").count == 3)
            #expect(!receipt.joins.contains { $0.rule == "ID-8" })
        }
    }

    @Test("WIN-14: a later move or Undo can keep the server's place and delete marks")
    func moveAndUndoIntoTakenNames() async throws {
        let base = try await World.make("cc000000")
        let other = StudySet.attemptID(92)
        for undo in [false, true] {
            let phone = try base.copy()
            let server = try base.copy()
            try server.store.run(
                "INSERT INTO folder (id, name, course_id, sort_order, created_at) SELECT ?, name, course_id, 2, created_at FROM folder", [.text(other)])
            if undo {
                try server.store.run("UPDATE folder SET course_exam_id = NULL, deleted_at = ?, deletion_id = id WHERE id = ?", [.text(World.later), .text(base.folder)])
            }
            try phone.store.run("UPDATE folder SET course_exam_id = NULL, updated_at = ?, sort_order = 3", [.text(World.newest)])
            let (result, receipt) = try phone.combine(into: server)
            let sql = "SELECT name, course_exam_id, deleted_at, deletion_id FROM folder WHERE id = ?"
            #expect(try result.run(sql, [.text(base.folder)]) == server.store.run(sql, [.text(base.folder)]))
            #expect(receipt.namesKept == [.init(table: "folders", id: base.folder)])
        }
    }

    @Test("ID-14: conflicting answer identities refuse the combine before either answer can be lost")
    func contradictoryAnswerIdentities() async throws {
        let server = try await World.make("cc000000")
        try await server.study.answer(0, choice: 2, number: 1)
        try await server.study.answer(1, choice: 1, number: 2)
        let phone = try server.copy()
        // Both archives have unique ids and client ids, but matching by id and by client
        // would select different server answers.
        try phone.store.run("UPDATE attempt SET client_attempt_id = ? WHERE client_attempt_id = ?", [.text(StudySet.attemptID(3)), .text(StudySet.attemptID(2))])
        try phone.store.run("UPDATE attempt SET client_attempt_id = ? WHERE client_attempt_id = ?", [.text(StudySet.attemptID(2)), .text(StudySet.attemptID(1))])
        #expect(throws: BankArchiveError.self) { try phone.combine(into: server) }
    }

    @Test("Only a complete server snapshot with its download stamp can produce a result")
    func snapshotPreconditions() async throws {
        let bank = try await World.make("cc000000")
        let local = try World.archive(bank.store)
        #expect(throws: BankArchiveError.self) { try BankCombine.combine(phone: local, server: local, at: World.date) }
        var incomplete = try ArchiveWorld.parsed(World.archive(bank.store, server: true))
        incomplete["complete"] = false
        #expect(throws: BankArchiveError.incomplete) { try BankCombine.combine(phone: local, server: ArchiveWorld.serialized(incomplete), at: World.date) }
    }

    @Test("WIN-10: check C covers the questions the combine changed, so a server progress row it left alone never stops a switch")
    func untouchedServerProgress() async throws {
        let server = try await World.make("cc000000")
        try await server.study.answer(0, choice: 2, number: 1)
        try await server.study.answer(1, choice: 2, number: 2)
        let other = try #require(try server.store.run("SELECT lineage_id FROM question WHERE id = ?", [.text(server.study.questions[1])]).first?[0])
        // A row the server keeps by its own rules, which a rebuild from its one answer would not give.
        try server.store.run("UPDATE question_progress SET attempts = 5, in_review = 0 WHERE question_lineage_id = ?", [other])
        let phone = try await World.make("dd000000")
        phone.study.harness.set(World.date.addingTimeInterval(10))
        try await phone.study.answer(0, choice: 0, number: 3)
        let (store, _) = try phone.combine(into: server)
        let sql = "SELECT attempts, in_review FROM question_progress WHERE question_lineage_id = ?"
        #expect(try store.run(sql, [other]) == server.store.run(sql, [other]))
        let changed = try #require(try store.run("SELECT lineage_id FROM question WHERE id = ?", [.text(server.study.questions[0])]).first?[0])
        #expect(try store.run("SELECT attempts, correct_attempts, last_status FROM question_progress WHERE question_lineage_id = ?", [changed]).first?.values == [2, 1, "correct"])
    }

    @Test("WIN-10: check C refuses a stored progress row of a question the combine changed that differs from a fresh rebuild")
    func wrongAffectedProgress() async throws {
        let server = try await World.make("cc000000")
        try await server.study.answer(1, choice: 2, number: 1)
        let phone = try await World.make("dd000000")
        try await phone.study.answer(0, choice: 0, number: 2)
        let changed = try #require(try server.store.run("SELECT lineage_id FROM question WHERE id = ?", [.text(server.study.questions[0])]).first?[0])
        let untouched = try #require(try server.store.run("SELECT lineage_id FROM question WHERE id = ?", [.text(server.study.questions[1])]).first?[0])
        for (lineage, refused) in [(changed, true), (untouched, false)] {
            var plan = try CombinePlan(phone: CombineBank(World.archive(phone.store)), server: CombineBank(World.archive(server.store, server: true)), now: World.date)
            try plan.combineCatalog()
            try plan.combineSets()
            try plan.combineStudy()
            try LocalStore.inMemory().transaction { tx in
                try plan.store(in: tx, stamp: World.stamp)
                try plan.closeCompetingExams(in: tx)
                try plan.rebuildProgress(in: tx)
                try plan.check(in: tx)
                try tx.execute("UPDATE question_progress SET attempts = attempts + 1 WHERE question_lineage_id = ?", [lineage])
                #expect(try tx.rows("SELECT attempts FROM question_progress WHERE question_lineage_id = ?", [lineage]).first?.integer("attempts") == 2)
                if refused {
                    #expect(throws: BankArchiveError.self) { try plan.check(in: tx) }
                } else {
                    try plan.check(in: tx)
                }
            }
        }
    }

    @Test("A refused combine leaves the free bank file as it was")
    func failurePreservesFreeBank() async throws {
        let initial = try await World.make("dd000000")
        try await initial.study.answer(0, choice: 1, number: 1)
        try await initial.study.answer(1, choice: 0, number: 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try LocalStore.open(directory: directory)
        try BankArchive.read(World.archive(initial.store), into: disk)
        let before = try World.archive(disk)
        // ID-14: matching by id and by client id would pick different answers.
        let other = try initial.copy()
        try other.store.run("UPDATE attempt SET client_attempt_id = ? WHERE client_attempt_id = ?", [.text(StudySet.attemptID(3)), .text(StudySet.attemptID(2))])
        try other.store.run("UPDATE attempt SET client_attempt_id = ? WHERE client_attempt_id = ?", [.text(StudySet.attemptID(2)), .text(StudySet.attemptID(1))])
        #expect(throws: BankArchiveError.self) { try BankCombine.combine(phone: before, server: World.archive(other.store, server: true), at: World.date) }
        #expect(try World.archive(disk) == before)
        #expect(try ArchiveWorld.dump(disk) == ArchiveWorld.dump(initial.store))
    }
}
