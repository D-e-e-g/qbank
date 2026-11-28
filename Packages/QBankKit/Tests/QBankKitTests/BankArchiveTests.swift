import Foundation
import Testing

@testable import QBankKit

/// The bank archive on the phone: the whole bank written as bank archive v1 and read into a fresh
/// bank, with a count check. Invented data only.
@Suite struct BankArchiveTests {
    // MARK: Round trip

    @Test func aBankReadsBackEqualToTheOriginalTableByTable() async throws {
        let world = try await ArchiveWorld.make()
        let counts = try BankArchive.counts(of: world.store)
        // Every table holds something, so equality is not equality of empty tables.
        for key in BankArchive.tableKeys { #expect((counts[key] ?? 0) > 0, "\(key) is empty in the test bank") }

        let archive = try BankArchive.write(from: world.store, at: ArchiveWorld.date)
        let fresh = try ArchiveWorld.empty()
        let stored = try BankArchive.read(archive, into: fresh)

        #expect(stored == counts)
        #expect(try ArchiveWorld.dump(fresh) == ArchiveWorld.dump(world.store))
        // The new bank writes the same document, byte for byte.
        #expect(try BankArchive.write(from: fresh, at: ArchiveWorld.date) == archive)
    }

    @Test func aBankWithNothingInItRoundTrips() throws {
        let store = try ArchiveWorld.empty()
        let archive = try BankArchive.write(from: store, at: ArchiveWorld.date)
        let fresh = try ArchiveWorld.empty()
        #expect(try BankArchive.read(archive, into: fresh) == BankArchive.counts(of: store))
        #expect(try ArchiveWorld.isEmpty(fresh))
    }

    @Test func anEmptyBankKeepsTheExactDownloadStampAndAnOlderArchiveHasNone() throws {
        let store = try ArchiveWorld.empty()
        let original = try BankArchive.write(from: store, at: ArchiveWorld.date)
        var document = try ArchiveWorld.parsed(original)
        #expect(document["stamp"] == nil)
        let stamp = "bank two\n\""
        document["stamp"] = stamp
        try BankArchive.read(ArchiveWorld.serialized(document), into: store)
        #expect(try ArchiveWorld.parsed(BankArchive.write(from: store, at: ArchiveWorld.date))["stamp"] as? String == stamp)
        try BankArchive.read(original, into: store)
        #expect(try BankArchive.write(from: store, at: ArchiveWorld.date) == original)
    }

    @Test func aSetWithOneTermKeyTwiceRoundTripsWithBothTerms() async throws {
        let world = try await ArchiveWorld.make()
        // The format and the server's term table name no unique key in a set, so a second definition of a key is a row like any other.
        try world.store.run(
            "INSERT INTO term (id, set_id, key, term, meaning) SELECT 'ffffffff-0000-4000-8000-000000000001', set_id, key, term || ' again', meaning FROM term LIMIT 1")
        let twice = try world.store.run("SELECT count(*) AS n FROM term GROUP BY set_id, key HAVING count(*) > 1")
        #expect(twice.count == 1)

        let archive = try BankArchive.write(from: world.store, at: ArchiveWorld.date)
        let fresh = try ArchiveWorld.empty()
        let stored = try BankArchive.read(archive, into: fresh)

        #expect(try stored == BankArchive.counts(of: world.store))
        #expect(try ArchiveWorld.dump(fresh) == ArchiveWorld.dump(world.store))
    }

    @Test func jsonAndTextComeBackExactlyAsStored() async throws {
        let world = try await ArchiveWorld.make()
        // Spelling a value's own form: whitespace, an escape, a slash, a trailing zero, a big number, text with quotes and a line break.
        try world.store.run(
            #"UPDATE question SET body = '{ "z": "é\/", "n": 1.50, "big": 12345678901234567890, "list": [ 3, 1, 2 ] }', stem = 'He said "hi"' || char(10) || 'then left.' WHERE position = 1"#)
        let archive = try BankArchive.write(from: world.store, at: ArchiveWorld.date)
        let fresh = try ArchiveWorld.empty()
        try BankArchive.read(archive, into: fresh)
        #expect(try ArchiveWorld.dump(fresh) == ArchiveWorld.dump(world.store))
        let body = try fresh.run("SELECT body FROM question WHERE body LIKE '%big%' LIMIT 1")[0].text("body")
        #expect(body == #"{ "z": "é\/", "n": 1.50, "big": 12345678901234567890, "list": [ 3, 1, 2 ] }"#)
    }

    // MARK: The document

    @Test func theDocumentHasTheFormatsHeaderKeysThenTablesInOrderWithRowsByKey() async throws {
        let world = try await ArchiveWorld.make()
        let data = try BankArchive.write(from: world.store, at: ArchiveWorld.date)
        let document = try ArchiveScanner.scan(data)
        guard case .object(let pairs) = document.root.kind else { Issue.record("the document is not an object"); return }
        #expect(pairs.map(\.key) == ["format", "version", "exportedAt", "writtenBy", "complete", "counts"] + BankArchive.tableKeys)

        let top = try #require(document.root.fields)
        #expect(top["format"]?.string == "qbank-bank-archive" && top["version"]?.integer == 1 && top["writtenBy"]?.string == "phone" && top["complete"]?.bool == true)
        #expect(top["exportedAt"]?.string == QBankJSON.formatDate(ArchiveWorld.date))
        let counts = try #require(top["counts"]?.fields)
        for table in BankArchiveTables.all {
            let node = try #require(top[table.key])
            let rows = table.single ? (node.isNull ? [] : [node]) : try #require(node.items)
            #expect(counts[table.key]?.integer == Int64(rows.count))
            let keys = rows.compactMap { row in table.rowKey.flatMap { row.fields?[$0]?.string } }
            #expect(keys == keys.sorted(), "\(table.key) is not in key order")
            for row in rows {
                let keys = Set(try #require(row.fields).keys)
                #expect(Set(table.fields.filter { !$0.optional }.map(\.name)).isSubset(of: keys))
                #expect(keys.isSubset(of: Set(table.fields.map(\.name))))
            }
        }
    }

    @Test func aNumberIsAWholeNumberAndABoolIsTrueOrFalse() async throws {
        let world = try await ArchiveWorld.make()
        let document = try ArchiveScanner.scan(BankArchive.write(from: world.store, at: ArchiveWorld.date))
        let top = try #require(document.root.fields)
        let questions = try #require(top["questions"]?.items)
        #expect(!questions.isEmpty && questions.allSatisfy { $0.fields?["position"]?.integer != nil && $0.fields?["body"]?.isObject == true && $0.fields?["termKeys"]?.isArray == true })
        let sets = try #require(top["practiceSets"]?.items).compactMap(\.fields)
        #expect(sets.contains { $0["isCurrent"]?.bool == false } && sets.contains { $0["isCurrent"]?.bool == true })
        #expect(sets.contains { $0["deletedAt"]?.string != nil } && sets.contains { $0["deletedAt"]?.isNull == true })
    }

    // MARK: The server's recording

    @Test func anArchiveRecordedFromTheServerLoads() throws {
        let recording = try ArchiveWorld.recording()
        let fresh = try ArchiveWorld.empty()
        let stored = try BankArchive.read(recording, into: fresh)

        let document = try ArchiveWorld.parsed(recording)
        let declared = try #require(document["counts"] as? [String: Int])
        #expect(stored.values == declared)
        // The recording is a bank with a row in every table, deleted rows and an older version of a set among them.
        #expect(stored.values.values.allSatisfy { $0 > 0 })
        #expect(try fresh.run("SELECT count(*) AS n FROM practice_set WHERE is_current = 0")[0].int("n") ?? 0 > 0)
        #expect(try fresh.run("SELECT count(*) AS n FROM practice_set WHERE deleted_at IS NOT NULL")[0].int("n") ?? 0 > 0)
    }

    @Test func theRecordedBankWrittenAgainHoldsTheSameRows() throws {
        let recording = try ArchiveWorld.recording()
        let directory = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imported = try LocalStore.open(directory: directory)
        try BankArchive.read(recording, into: imported)
        imported.close()
        let fresh = try LocalStore.open(directory: directory)
        let written = try ArchiveWorld.parsed(BankArchive.write(from: fresh, at: ArchiveWorld.date))
        let recorded = try ArchiveWorld.parsed(recording)
        #expect(written["writtenBy"] as? String == "phone" && recorded["writtenBy"] as? String == "server")
        let stamp = try #require(recorded["stamp"] as? String)
        #expect(written["stamp"] as? String == stamp)
        // Equal as JSON, with each list in key order: readers never depend on order, and the recording's ids were renumbered after the server sorted it.
        func canonical(_ document: [String: Any], _ key: String, by rowKey: String?) throws -> Data {
            var value = document[key] as Any
            if let rowKey, let rows = value as? [[String: Any]] { value = rows.sorted { ($0[rowKey] as? String ?? "") < ($1[rowKey] as? String ?? "") } }
            return try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        }
        #expect(try canonical(written, "counts", by: nil) == canonical(recorded, "counts", by: nil))
        for table in BankArchiveTables.all {
            #expect(try canonical(written, table.key, by: table.rowKey) == canonical(recorded, table.key, by: table.rowKey), "\(table.key) differs")
        }
    }

    @Test func theRecordedBankHasNoIdOfARealAccount() throws {
        // Every id of the recording is a fixed synthetic one, and there is no email or token in it.
        let text = String(decoding: try ArchiveWorld.recording(), as: UTF8.self)
        #expect(!text.contains("@") && !text.localizedCaseInsensitiveContains("token"))
    }

    // MARK: Counts

    @Test func countsNeedAllTwelveTablesAndDecodeFromTheServersAnswer() throws {
        let full = Dictionary(uniqueKeysWithValues: BankArchive.tableKeys.map { ($0, 1) })
        #expect(BankCounts(full) != nil)
        #expect(BankCounts(full.filter { $0.key != "terms" }) == nil)
        #expect(BankCounts(full.merging(["extra": 1]) { $1 }) == nil)
        #expect(BankCounts(full.merging(["terms": -1]) { $1 }) == nil)
        let answer = try JSONSerialization.data(withJSONObject: ["counts": full])
        struct Answer: Decodable { let counts: BankCounts }
        #expect(try JSONDecoder().decode(Answer.self, from: answer).counts == BankCounts(full))
        let short = try JSONSerialization.data(withJSONObject: ["counts": ["terms": 1]])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Answer.self, from: short) }
    }

    @Test func theCountsOfAStoreAreItsRowsDeletedRowsIncluded() async throws {
        let world = try await ArchiveWorld.make()
        let counts = try BankArchive.counts(of: world.store)
        for table in BankArchiveTables.all {
            #expect(counts[table.key] == (try world.store.run("SELECT count(*) AS n FROM \(table.table)")[0].int("n")))
        }
        #expect(counts["practiceSets"] == (try world.store.run("SELECT count(*) AS n FROM practice_set WHERE deleted_at IS NULL")[0].int("n") ?? 0) + 1)
    }
}
