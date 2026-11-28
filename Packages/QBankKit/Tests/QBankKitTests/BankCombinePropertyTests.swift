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
        let joins = Dictionary(grouping: first.ledger.joins, by: \.table)
        let counts = try BankArchive.counts(of: stored)
        let localCounts = try BankArchive.counts(of: phone.store)
        let remoteCounts = try BankArchive.counts(of: server.store)
        for table in BankArchiveTables.all {
            let key = table.rowKey.map(table.column(of:)) ?? "'place'"
            let sql = "SELECT \(key) AS key FROM \(table.table)"
            let resultKeys = Set(try stored.run(sql).map { $0.string("key") })
            let serverKeys = Set(try server.store.run(sql).map { $0.string("key") })
            let phoneKeys = Set(try phone.store.run(sql).map { $0.string("key") })
            let pairs = Dictionary(uniqueKeysWithValues: (joins[table.key] ?? []).map { ($0.phoneKey, $0.serverKey) })
            #expect(serverKeys.isSubset(of: resultKeys))
            // A progress row can acquire the other import's question lineage even when only
            // the phone answered that question. Read its canonical lineage through the question.
            var mapped: Set<String> = []
            for source in phoneKeys {
                if table.key == "questionProgress", pairs[source] == nil, sharedFile {
                    let sql = "SELECT position FROM question WHERE lineage_id = ?"
                    let position = try #require(try phone.store.run(sql, [.text(source)]).first?[0])
                    let target = try #require(try server.store.run("SELECT lineage_id FROM question WHERE position = ?", [position]).first?.text("lineage_id"))
                    mapped.insert(target)
                } else {
                    mapped.insert(pairs[source] ?? source)
                }
            }
            #expect(resultKeys == serverKeys.union(mapped))
            #expect(counts[table.key] == (localCounts[table.key] ?? 0) + (remoteCounts[table.key] ?? 0) - pairs.count)
        }
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
