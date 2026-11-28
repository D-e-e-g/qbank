import Foundation
import Testing

@testable import QBankKit

extension BankCombineTests {
    @Test("Generated banks account for every key, answer and progress line, and a repeated combine is stable", arguments: 0..<24)
    func generated(_ seed: Int) async throws {
        let count = 1 + seed % 4
        let server = try await World.make("cc000000", count: count)
        let phone = try await World.make("dd000000", count: count)
        let sharedFile = seed % 3 != 0
        if !sharedFile { try phone.store.run("UPDATE folder SET name = 'Other folder'") }
        let empty = try LocalStore.inMemory()
        var expectedAnswers: Set<String> = []
        for (side, world) in [server, phone].enumerated() {
            for index in 0..<(1 + (seed + side * 3) % 6) {
                let repeated = sharedFile && index == 0 && seed.isMultiple(of: 2)
                let number = repeated ? 0 : 1 + index + 10 * side
                world.study.harness.set(World.date.addingTimeInterval(Double(number)))
                let answer = try await world.study.answer((index + seed) % count, choice: (index + seed) % 3, number: number, guessed: index.isMultiple(of: 3))
                #expect((200..<300).contains(answer.status))
                expectedAnswers.insert(StudySet.attemptID(number))
            }
        }
        let local = try World.archive(phone.store)
        let remote = try World.archive(server.store, server: true)
        let first = try BankCombine.combine(phone: local, server: remote, at: World.date)
        let retried = try BankCombine.combine(phone: local, server: first.archive, at: World.date)
        #expect(retried.archive == first.archive)
        let stored = try LocalStore.inMemory()
        try BankArchive.read(first.archive, into: stored)
        let answers = try stored.run("SELECT client_attempt_id FROM attempt")
        #expect(Set(answers.map { $0.string("client_attempt_id") }) == expectedAnswers)
        #expect(answers.count == expectedAnswers.count)
        // The worlds differ only in their ids and, when the file is not shared, the folder's name.
        // A row of either bank is the same item as one of the other when it has the same place in
        // what both built: the semester number, the course code or topic title, the page and folder
        // name, a set's folder and file, a question's position, a term's key and an answer's client id.
        let set = "(SELECT lower(f.name) || '/' || ps.file_hash FROM practice_set ps JOIN folder f ON f.id = ps.folder_id WHERE ps.id = %@)"
        let question = "(SELECT \(set.replacingOccurrences(of: "%@", with: "q.set_id")) || '#' || q.position FROM question q WHERE q.lineage_id = %@ LIMIT 1)"
        let places: [String: String] = [
            "semesters": "SELECT id AS key, CAST(number AS TEXT) AS place FROM semester",
            "courses": "SELECT id AS key, kind || ':' || lower(CASE kind WHEN 'topic' THEN title ELSE code END) AS place FROM course",
            "courseExams": "SELECT id AS key, lower(name) AS place FROM course_exam",
            "folders": "SELECT id AS key, lower(name) AS place FROM folder",
            "practiceSets": "SELECT id AS key, \(set.replacingOccurrences(of: "%@", with: "practice_set.id")) AS place FROM practice_set",
            "questions": "SELECT id AS key, \(set.replacingOccurrences(of: "%@", with: "question.set_id")) || '#' || position AS place FROM question",
            "terms": "SELECT id AS key, \(set.replacingOccurrences(of: "%@", with: "term.set_id")) || '#' || key AS place FROM term",
            "studySessions": "SELECT id AS key, id AS place FROM study_session",
            "attempts": "SELECT id AS key, client_attempt_id AS place FROM attempt",
            "questionProgress": "SELECT question_lineage_id AS key, \(question.replacingOccurrences(of: "%@", with: "question_lineage_id")) AS place FROM question_progress",
            "reviewClears": "SELECT question_lineage_id AS key, \(question.replacingOccurrences(of: "%@", with: "question_lineage_id")) AS place FROM review_clear",
            "studyPlace": "SELECT 'place' AS key, 'place' AS place FROM study_place",
        ]
        // Progress and clears follow their question to the server's lineage even when only the phone has a row.
        let lineages = Dictionary(
            uniqueKeysWithValues: try server.store.run("SELECT DISTINCT o.lineage_id AS key, \(question.replacingOccurrences(of: "%@", with: "o.lineage_id")) AS place FROM question o")
                .compactMap { row in row.text("place").map { ($0, row.string("key")) } })
        let counts = try BankArchive.counts(of: stored)
        var joined = 0
        for table in BankArchiveTables.all {
            let sql = try #require(places[table.key])
            let key = table.rowKey.map(table.column(of:)) ?? "'place'"
            let resultKeys = Set(try stored.run("SELECT \(key) AS key FROM \(table.table)").map { $0.string("key") })
            func read(_ store: LocalStore) throws -> [(key: String, place: String)] {
                try store.run(sql).map { row in (row.string("key"), try #require(row.text("place"))) }
            }
            let held = try read(server.store)
            let serverByPlace = Dictionary(uniqueKeysWithValues: held.map { ($0.place, $0.key) })
            let incoming = try read(phone.store)
            let follows = table.key == "questionProgress" || table.key == "reviewClears" ? lineages : serverByPlace
            let mapped = Set(incoming.map { follows[$0.place] ?? $0.key })
            let paired = incoming.filter { serverByPlace[$0.place] != nil }.count
            joined += paired
            #expect(resultKeys == Set(held.map(\.key)).union(mapped), "\(table.key)")
            #expect(counts[table.key] == held.count + incoming.count - paired, "\(table.key)")
        }
        #expect(joined > 0)
        let beforeRebuild = try stored.run("SELECT * FROM question_progress ORDER BY question_lineage_id")
        try stored.transaction { tx in
            let ids = try tx.rows("SELECT lineage_id FROM question").map { $0.string("lineage_id") }
            try ProgressRebuild.rebuild(tx, lineageIDs: ids)
        }
        #expect(try stored.run("SELECT * FROM question_progress ORDER BY question_lineage_id") == beforeRebuild)
        let downloaded = try LocalStore.inMemory()
        try BankArchive.read(remote, into: downloaded)
        for input in [remote, try World.archive(empty)] {
            let same = try BankCombine.combine(phone: input, server: remote, at: World.date)
            let check = try LocalStore.inMemory()
            try BankArchive.read(same.archive, into: check)
            #expect(try ArchiveWorld.dump(check) == ArchiveWorld.dump(downloaded))
        }
        let phoneOnly = try BankCombine.combine(phone: local, server: World.archive(empty, server: true), at: World.date)
        let phoneCopy = try LocalStore.inMemory()
        try BankArchive.read(phoneOnly.archive, into: phoneCopy)
        #expect(try ArchiveWorld.dump(phoneCopy) == ArchiveWorld.dump(phone.store))
    }

    @Test("Two devices editing during a lapse converge in either upload order")
    func twoDevicesAfterALapse() async throws {
        let original = try await World.make("cc000000")
        let first = try original.copy()
        let second = try original.copy()
        for (world, name, offset) in [(first, "First", 10.0), (second, "Last", 20.0)] {
            world.study.harness.set(World.date.addingTimeInterval(offset))
            let rename = try await world.study.harness.send("PATCH", "/api/folders/\(world.folder)", .object(["name": .string(name)]))
            #expect(rename.status == 200)
        }
        try await first.study.answer(0, choice: 0, number: 1)
        // Give the second device independent event ids in this copy of the shared catalog.
        let bank = LocalBankHarness(store: second.store, idPrefix: "aa000000")
        let study = StudySet(harness: bank, course: second.study.course, setID: second.study.setID, questions: second.study.questions)
        bank.set(World.date.addingTimeInterval(10))
        try await study.answer(1, choice: 1, number: 2)
        let remote = try World.archive(original.store, server: true)
        func upload(_ a: World, _ b: World) throws -> Data {
            let initial = try BankCombine.combine(phone: World.archive(a.store), server: remote, at: World.date)
            return try BankCombine.combine(phone: World.archive(b.store), server: initial.archive, at: World.date).archive
        }
        let both = try upload(first, second)
        #expect(try both == upload(second, first))
        let result = try LocalStore.inMemory()
        try BankArchive.read(both, into: result)
        #expect(try result.run("SELECT name FROM folder").first?[0] == "Last")
        #expect(try result.run("SELECT id FROM attempt").count == 2)
    }
}
