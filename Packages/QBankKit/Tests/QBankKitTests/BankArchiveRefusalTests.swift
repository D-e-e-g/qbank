import Foundation
import Testing

@testable import QBankKit

/// A file that is cut off, altered, or not the format loads nothing and leaves the bank it was
/// offered to as it was. Invented data only.
@Suite struct BankArchiveRefusalTests {
    typealias Document = [String: Any]

    private static let spare = "ffffffff-0000-4000-8000-0000000000"

    /// Reads `data` into an empty bank and into a bank that holds the test world, and checks that each
    /// one refused with an error `expected` accepts, and is exactly as it was.
    private func refused(_ name: String, _ data: Data, world: LocalStore, before: [String: [[StoreValue]]], _ expected: (BankArchiveError) -> Bool) throws {
        let fresh = try ArchiveWorld.empty()
        do {
            try BankArchive.read(data, into: fresh)
            Issue.record("\(name): the file was loaded")
        } catch let error as BankArchiveError {
            #expect(expected(error), "\(name): refused for another reason: \(error)")
        }
        #expect(try ArchiveWorld.isEmpty(fresh), "\(name): the empty bank holds rows")

        do {
            try BankArchive.read(data, into: world)
            Issue.record("\(name): the file was loaded into a bank that has one")
        } catch is BankArchiveError {}
        #expect(try ArchiveWorld.dump(world) == before, "\(name): the existing bank changed")
    }

    private func edited(_ change: (inout Document) throws -> Void) throws -> Data {
        var document = try ArchiveWorld.parsed(ArchiveWorld.recording())
        try change(&document)
        return try ArchiveWorld.serialized(document)
    }

    private func rows(_ document: Document, _ key: String) -> [[String: Any]] { document[key] as? [[String: Any]] ?? [] }

    /// Adds a row to a table and counts it, so the damage is in the row and not in the count.
    private func adding(_ document: inout Document, _ key: String, _ row: [String: Any]) {
        document[key] = rows(document, key) + [row]
        var counts = document["counts"] as? [String: Int] ?? [:]
        counts[key, default: 0] += 1
        document["counts"] = counts
    }

    private func removing(_ document: inout Document, _ key: String, where match: ([String: Any]) -> Bool) {
        let kept = rows(document, key).filter { !match($0) }
        var counts = document["counts"] as? [String: Int] ?? [:]
        counts[key] = kept.count
        document[key] = kept
        document["counts"] = counts
    }

    private func setting(_ document: inout Document, _ key: String, row index: Int = 0, _ field: String, _ value: Any?) {
        var list = rows(document, key)
        if let value { list[index][field] = value } else { list[index].removeValue(forKey: field) }
        document[key] = list
    }

    // MARK: Cut off

    @Test func aFileCutOffAnywhereLoadsNothing() async throws {
        let world = try await ArchiveWorld.make()
        let before = try ArchiveWorld.dump(world.store)
        let data = try ArchiveWorld.recording()
        let closing = try #require(data.lastIndex(of: UInt8(ascii: "}")))
        var cuts = Array(stride(from: 0, to: closing, by: max(1, closing / 120)))
        cuts += [closing, closing - 1, closing - 2, 1, 2]
        for cut in cuts {
            try refused("cut at \(cut)", data.prefix(cut), world: world.store, before: before) { if case .unreadable = $0 { true } else { false } }
        }
    }

    @Test func aFileCutOffAfterItsLastBraceIsStillTheWholeDocument() throws {
        let data = try ArchiveWorld.recording()
        let closing = try #require(data.lastIndex(of: UInt8(ascii: "}")))
        #expect(throws: Never.self) { try BankArchive.read(data.prefix(closing + 1), into: ArchiveWorld.empty()) }
    }

    // MARK: Not the format

    @Test func textThatIsNotADocumentOfTheFormatIsRefused() async throws {
        let world = try await ArchiveWorld.make()
        let before = try ArchiveWorld.dump(world.store)
        let recording = try ArchiveWorld.recording()
        let unreadable = { (error: BankArchiveError) in if case .unreadable = error { true } else { false } }
        let invalid = { (error: BankArchiveError) in if case .invalid = error { true } else { false } }
        let cases: [(String, Data, (BankArchiveError) -> Bool)] = [
            ("empty", Data(), unreadable),
            ("a space", Data(" ".utf8), unreadable),
            ("not UTF-8", Data([0x7B, 0xFF, 0xFE, 0x7D]), unreadable),
            ("junk after the document", recording + Data("{}".utf8), unreadable),
            ("a trailing comma", Data(#"{"format":"qbank-bank-archive",}"#.utf8), unreadable),
            ("a comment", Data("{} // note".utf8), unreadable),
            ("a number with a leading zero", Data("{\"version\": 01}".utf8), unreadable),
            ("a lone surrogate", Data(#"{"a":"\ud800"}"#.utf8), unreadable),
            ("a list", Data("[]".utf8), { $0 == .notAnArchive }),
            ("a string", Data(#""qbank-bank-archive""#.utf8), { $0 == .notAnArchive }),
            ("an empty object", Data("{}".utf8), { $0 == .notAnArchive }),
            ("the progress export", Data(#"{"format":"nclex-qbank-progress","version":1}"#.utf8), { $0 == .notAnArchive }),
            ("a field twice", Data(#"{"format":"qbank-bank-archive","format":"x"}"#.utf8), invalid),
            ("a version that is text", try edited { $0["version"] = "1" }, invalid),
            ("a version that is a fraction", try edited { $0["version"] = 1.5 }, invalid),
            ("version 2", try edited { $0["version"] = 2 }, { $0 == .unsupportedVersion(2) }),
            ("version 0", try edited { $0["version"] = 0 }, { $0 == .unsupportedVersion(0) }),
            ("another format", try edited { $0["format"] = "nclex-qbank-progress" }, { $0 == .notAnArchive }),
            ("a bank that left rows out", try edited { $0["complete"] = false }, { $0 == .incomplete }),
            ("complete as text", try edited { $0["complete"] = "true" }, invalid),
            ("exportedAt that is not a time", try edited { $0["exportedAt"] = "yesterday" }, invalid),
            ("writtenBy anyone else", try edited { $0["writtenBy"] = "someone" }, invalid),
        ]
        for (name, data, expected) in cases { try refused(name, data, world: world.store, before: before, expected) }
    }

    // MARK: Counts and keys

    @Test func everyKeyMustBeThereAndEveryCountMustMatch() async throws {
        let world = try await ArchiveWorld.make()
        let before = try ArchiveWorld.dump(world.store)
        let invalid = { (error: BankArchiveError) in if case .invalid = error { true } else { false } }
        for key in ["exportedAt", "writtenBy", "complete", "counts"] + BankArchive.tableKeys {
            try refused("\(key) missing", try edited { $0.removeValue(forKey: key) }, world: world.store, before: before, invalid)
        }
        for key in BankArchive.tableKeys {
            try refused(
                "counts.\(key) missing",
                try edited {
                    var counts = $0["counts"] as? [String: Int] ?? [:]; counts.removeValue(forKey: key); $0["counts"] = counts
                }, world: world.store, before: before, invalid)
            for delta in [1, -1] {
                try refused(
                    "counts.\(key) off by \(delta)",
                    try edited {
                        var counts = $0["counts"] as? [String: Int] ?? [:]; counts[key, default: 0] += delta; $0["counts"] = counts
                    }, world: world.store,
                    before: before
                ) { error in
                    if case .countsDiffer(let table, _, _) = error { table == key } else { false }
                }
            }
        }
        // A row taken out of a list and the counts left as they were.
        for key in BankArchive.tableKeys where key != "studyPlace" {
            try refused("a \(key) row removed", try edited { $0[key] = Array(self.rows($0, key).dropLast()) }, world: world.store, before: before) { error in
                if case .countsDiffer(let table, _, _) = error { table == key } else { false }
            }
        }
        try refused("a place that is a list", try edited { $0["studyPlace"] = [Any]() }, world: world.store, before: before, invalid)
    }

    @Test func aDocumentThatBreaksARuleOfTheFormatIsRefusedWhateverItsCounts() async throws {
        let world = try await ArchiveWorld.make()
        let before = try ArchiveWorld.dump(world.store)
        let invalid = { (error: BankArchiveError) in if case .invalid = error { true } else { false } }
        let sample = try ArchiveWorld.parsed(ArchiveWorld.recording())
        let course = try #require(rows(sample, "courses").first { $0["kind"] as? String == "course" })
        let topic = try #require(rows(sample, "courses").first { $0["kind"] as? String == "topic" && $0["deletedAt"] is NSNull })
        let folder = try #require(rows(sample, "folders").first)
        let attempt = try #require(rows(sample, "attempts").first)
        let semester = try #require(rows(sample, "semesters").first)
        let spare = { (number: Int) in Self.spare + String(format: "%02d", number) }

        let cases: [(String, Data)] = [
            // Keys.
            (
                "a course id twice",
                try edited {
                    var copy = course; copy["title"] = "Another"; self.adding(&$0, "courses", copy)
                }
            ),
            (
                "an answer's client id twice",
                try edited {
                    var copy = attempt; copy["id"] = spare(1); self.adding(&$0, "attempts", copy)
                }
            ),
            ("a progress key twice", try edited { self.adding(&$0, "questionProgress", self.rows($0, "questionProgress")[0]) }),
            (
                "a semester number twice",
                try edited {
                    var copy = semester; copy["id"] = spare(2); self.adding(&$0, "semesters", copy)
                }
            ),
            (
                "two live topics with one title ignoring case",
                try edited {
                    var copy = topic; copy["id"] = spare(4); copy["title"] = (topic["title"] as? String ?? "").uppercased(); self.adding(&$0, "courses", copy)
                }
            ),
            (
                "two folders in one list with one name",
                try edited {
                    var copy = folder; copy["id"] = spare(5); self.adding(&$0, "folders", copy)
                }
            ),
            // References.
            ("a question in a set that is not there", try edited { self.setting(&$0, "questions", "setId", spare(6)) }),
            ("a set in a course that is not there", try edited { self.setting(&$0, "practiceSets", "courseId", spare(7)) }),
            ("a course in a semester that is not there", try edited { self.setting(&$0, "courses", row: 0, "semesterId", spare(8)) }),
            ("a folder on a page that is not there", try edited { self.setting(&$0, "folders", "courseExamId", spare(9)) }),
            ("an answer to a question that is not there", try edited { self.setting(&$0, "attempts", "questionId", spare(10)) }),
            ("progress on an answer that is not there", try edited { self.setting(&$0, "questionProgress", "lastAttemptId", spare(11)) }),
            ("the place in a course that is not there", try edited { $0["studyPlace"] = ["courseId": spare(12), "updatedAt": "2026-11-22T10:00:00.000Z"] }),
            (
                "a set removed from under its questions",
                try edited { doc in
                    let setID = self.rows(doc, "questions")[0]["setId"] as? String
                    self.removing(&doc, "practiceSets") { $0["id"] as? String == setID }
                }
            ),
            // Marks and the course rule.
            ("a delete mark without its id", try edited { self.setting(&$0, "practiceSets", "deletedAt", "2026-11-22T10:00:00.000Z") }),
            ("a delete id without its time", try edited { self.setting(&$0, "folders", "deletionId", spare(13)) }),
            (
                "a course with no semester",
                try edited { doc in
                    let index = self.rows(doc, "courses").firstIndex { $0["kind"] as? String == "course" } ?? 0
                    self.setting(&doc, "courses", row: index, "semesterId", NSNull())
                }
            ),
            (
                "a topic in a semester",
                try edited { doc in
                    let index = self.rows(doc, "courses").firstIndex { $0["kind"] as? String == "topic" } ?? 0
                    self.setting(&doc, "courses", row: index, "semesterId", semester["id"])
                }
            ),
            // Values of the wrong kind, and rows with a field missing.
            ("a field that is null but may not be", try edited { self.setting(&$0, "courses", "title", NSNull()) }),
            ("a field that is not there", try edited { self.setting(&$0, "courses", "title", nil) }),
            ("an id in capitals", try edited { self.setting(&$0, "questions", "lineageId", "AAAAAAAA-0000-4000-8000-000000000000") }),
            ("an id that is too short", try edited { self.setting(&$0, "questions", "lineageId", "1234") }),
            ("a time without milliseconds", try edited { self.setting(&$0, "courses", "createdAt", "2026-11-22T10:00:00Z") }),
            ("a time that is not a day", try edited { self.setting(&$0, "courses", "createdAt", "2026-02-30T10:00:00.000Z") }),
            ("a time with an hour of 24", try edited { self.setting(&$0, "courses", "createdAt", "2026-02-20T24:00:00.000Z") }),
            ("a date that is not a day", try edited { self.setting(&$0, "semesters", "startsOn", "2026-13-01") }),
            ("a position of 0", try edited { self.setting(&$0, "questions", "position", 0) }),
            ("a position with a fraction", try edited { self.setting(&$0, "questions", "position", 1.5) }),
            ("a semester number of 4", try edited { self.setting(&$0, "semesters", "number", 4) }),
            ("a bool that is a number", try edited { self.setting(&$0, "practiceSets", "isCurrent", 1) }),
            ("a word that is not one of the choices", try edited { self.setting(&$0, "courseExams", "badge", "party") }),
            ("stats that are a list", try edited { self.setting(&$0, "practiceSets", "stats", [Any]()) }),
            ("a question body that is text", try edited { self.setting(&$0, "questions", "body", "text") }),
            ("term keys that are an object", try edited { self.setting(&$0, "questions", "termKeys", [String: Any]()) }),
            ("an answer that is null", try edited { self.setting(&$0, "attempts", "response", NSNull()) }),
            ("a row that is not an object", try edited { $0["courses"] = [1] + self.rows($0, "courses").dropFirst().map { $0 as Any } }),
        ]
        for (name, data) in cases { try refused(name, data, world: world.store, before: before, invalid) }
    }

    // MARK: Nothing half stored

    @Test func aStoreThatFailsPartWayHoldsNothingOfTheDocument() throws {
        let store = try ArchiveWorld.empty()
        // The earlier tables take their rows; the store then refuses an answer, as a full disk would.
        try store.run("CREATE TRIGGER refuse_attempts BEFORE INSERT ON attempt BEGIN SELECT RAISE(ABORT, 'disk full'); END")
        #expect(throws: BankArchiveError.self) { try BankArchive.read(ArchiveWorld.recording(), into: store) }
        #expect(try ArchiveWorld.isEmpty(store))

        // The store is not damaged by it: once it takes answers again, the same document loads whole.
        try store.run("DROP TRIGGER refuse_attempts")
        let stored = try BankArchive.read(ArchiveWorld.recording(), into: store)
        #expect(try BankArchive.counts(of: store) == stored)
    }

    @Test func aGoodDocumentIsNotReadIntoABankThatAlreadyHoldsRows() async throws {
        let world = try await ArchiveWorld.make()
        let before = try ArchiveWorld.dump(world.store)
        #expect(throws: BankArchiveError.bankNotEmpty) { try BankArchive.read(ArchiveWorld.recording(), into: world.store) }
        #expect(try ArchiveWorld.dump(world.store) == before)

        // Even a bank with a single semester is not a fresh one.
        let almost = try ArchiveWorld.empty()
        try almost.run("INSERT INTO semester (id, number, name, created_at) VALUES ('00000000-0000-4000-8000-000000000001', 1, 'One', '2026-11-22T10:00:00.000Z')")
        #expect(throws: BankArchiveError.bankNotEmpty) { try BankArchive.read(ArchiveWorld.recording(), into: almost) }
        #expect(try BankArchive.counts(of: almost)["semesters"] == 1)
    }

    @Test func aRefusedFileDoesNotStopTheNextGoodOne() throws {
        let store = try ArchiveWorld.empty()
        let data = try ArchiveWorld.recording()
        let closing = try #require(data.lastIndex(of: UInt8(ascii: "}")))
        #expect(throws: BankArchiveError.self) { try BankArchive.read(data.prefix(closing), into: store) }
        #expect(try ArchiveWorld.isEmpty(store))
        #expect(try BankArchive.read(data, into: store).values["questions"] == 16)
    }
}
