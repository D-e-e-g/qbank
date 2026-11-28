import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// The hand-over record beside a bank, which says which side holds it and keeps a move's lease
/// across launches, and the store's hold on writes while a bank moves. Invented data only.
@Suite("The hand-over record and the hold")
struct BankHandoverTests {
    // MARK: The record

    @Test func aBankWithNoRecordIsOnThisPhoneWithNoMove() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try BankHandoverRecord.file(key: MoveWorld.key, in: root)
        #expect(try record.load() == .onPhone)
        #expect(!FileManager.default.fileExists(atPath: root.path), "reading makes no folder and no file")
        #expect(try BankHandoverRecord.inMemory().load() == .onPhone)
    }

    @Test func theRecordLivesBesideTheBankAndReadsBackAsWritten() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore.open(key: MoveWorld.key, in: root)
        let record = try BankHandoverRecord.file(key: MoveWorld.key, in: root)
        #expect(record.fileURL?.deletingLastPathComponent() == store.fileURL?.deletingLastPathComponent())
        #expect(record.fileURL?.lastPathComponent == "handover.json")

        let leased = BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start))
        try record.save(leased)
        #expect(try record.load() == leased)
        #expect(try BankHandoverRecord.file(key: MoveWorld.key, in: root).load() == leased, "another launch reads the same")
        let moved = BankHandover(authority: .cloud, movedToCloudAt: MoveWorld.start)
        try record.save(moved)
        #expect(try record.load() == moved)
        let text = try String(contentsOf: try #require(record.fileURL), encoding: .utf8)
        #expect(text == #"{"authority":"cloud","bankFile":"bank.sqlite","movedToCloudAt":"2027-01-15T08:00:00.000Z","version":2}"#)
    }

    @Test func aRecordOfTheFirstVersionNamesTheFirstFile() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try BankHandoverRecord.file(key: MoveWorld.key, in: root)
        let file = try #require(record.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // As the move to QBank Cloud wrote it before records named a file.
        try Data(#"{"authority":"cloud","movedToCloudAt":"2027-01-15T08:00:00.000Z","version":1}"#.utf8).write(to: file)

        let found = try record.load()
        #expect(found.version == 1)
        #expect(found.authority == .cloud)
        #expect(found.bankFile == LocalStore.firstFile)
        #expect(found.bankStamp == nil)
        #expect(found.inCloud(since: MoveWorld.start) == BankHandover(authority: .cloud, movedToCloudAt: MoveWorld.start))
    }

    /// A record an earlier build wrote while it offered sets reads as one without them, and its sets
    /// stay in the file that holds them.
    @Test func aRecordThatOfferedSetsReadsAsOneWithout() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try BankHandoverRecord.file(key: MoveWorld.key, in: root)
        let file = try #require(record.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"authority":"cloud","bankFile":"bank.sqlite","movedToCloudAt":"2027-01-15T08:00:00.000Z","offeredFile":"bank.sqlite","offeredSets":["s1"],"version":2}"#.utf8)
            .write(to: file)

        #expect(try record.load() == BankHandover(authority: .cloud, movedToCloudAt: MoveWorld.start))
    }

    @Test func aRecordKeepsItsBankFileAndTheStampItTookInAcrossEveryChange() {
        let back = BankHandover.onPhone.inCloud(since: MoveWorld.start).onPhone(in: "bank-20270115T080000000Z.sqlite", since: MoveWorld.start, stamp: "stamp-1")
        #expect(back.authority == .phone)
        #expect(back.bankFile == "bank-20270115T080000000Z.sqlite")
        #expect(back.returnedAt == MoveWorld.start)
        #expect(back.movedToCloudAt == MoveWorld.start)
        #expect(back.bankStamp == "stamp-1")
        let leased = back.leased(.init(direction: .toCloud, startedAt: MoveWorld.start, combines: true))
        #expect(leased.bankFile == back.bankFile)
        #expect(leased.bankStamp == "stamp-1")
        #expect(leased.lease?.combines == true)
        let moved = leased.inCloud(since: MoveWorld.start)
        #expect(moved.bankFile == back.bankFile, "a bank that moves again keeps its file as the safety copy")
        #expect(moved.lease == nil)
        #expect(moved.bankStamp == "stamp-1")
    }

    /// A move's lease is written as before combines were built; a combine's carries its mark.
    @Test func aCombinesLeaseCarriesItsMarkAndAMovesIsWrittenAsBefore() throws {
        let move = BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start))
        let combine = BankHandover.onPhone.leased(.init(direction: .toPhone, startedAt: MoveWorld.start, file: "bank-20270115T080000000Z.sqlite", combines: true))
        let encoder = QBankJSON.encoder
        #expect(
            String(decoding: try encoder.encode(move), as: UTF8.self)
                == #"{"authority":"phone","bankFile":"bank.sqlite","lease":{"direction":"toCloud","startedAt":"2027-01-15T08:00:00.000Z"},"version":2}"#)
        #expect(
            String(decoding: try encoder.encode(combine), as: UTF8.self)
                == #"{"authority":"phone","bankFile":"bank.sqlite","lease":{"combines":true,"direction":"toPhone","file":"bank-20270115T080000000Z.sqlite","startedAt":"2027-01-15T08:00:00.000Z"},"version":2}"#
        )
        for handover in [move, combine] {
            #expect(try QBankJSON.decoder.decode(BankHandover.self, from: encoder.encode(handover)) == handover)
        }
    }

    @Test(arguments: [
        "not json", #"{"authority":"cloud","version":3}"#, #"{"authority":"somewhere","version":1}"#, #"{"version":1}"#,
        #"{"authority":"phone","lease":{"direction":"sideways","startedAt":"2027-01-15T08:00:00.000Z"},"version":1}"#,
        #"{"authority":"phone","bankFile":"../elsewhere.sqlite","version":2}"#,
        #"{"authority":"cloud","lease":{"direction":"toPhone","file":"handover.json","startedAt":"2027-01-15T08:00:00.000Z"},"version":2}"#,
    ])
    func aRecordThisAppCannotReadIsNeverTakenForEitherSideAndIsLeftAsItIs(_ text: String) throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try BankHandoverRecord.file(key: MoveWorld.key, in: root)
        let file = try #require(record.fileURL)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)

        #expect {
            try record.load()
        } throws: { error in
            guard case StoreError.unreadableHandover = error else { return false }
            return true
        }
        #expect(try Data(contentsOf: file) == Data(text.utf8))
    }

    @Test func aKeyThatIsNotOneFolderNamesNoRecord() {
        #expect(throws: StoreError.invalidKey("../elsewhere")) {
            try BankHandoverRecord.file(key: "../elsewhere", in: StoreFixtures.temporaryDirectory())
        }
    }

    // MARK: The hold

    @Test func aHeldBankRefusesEveryWriteAndStillAnswersReads() async throws {
        let harness = try LocalBankHarness()
        let topic = try await harness.send("POST", "/api/topics", .object(["title": .string("Invented Geography")]))
        #expect(topic.status == 201)
        let rows = try ArchiveWorld.dump(harness.store)

        harness.store.holdWrites()
        #expect(harness.store.holdsWrites)
        let refused = try await harness.send("POST", "/api/topics", .object(["title": .string("Invented History")]))
        #expect(refused.status == 409)
        #expect(refused.body["error"]?.stringValue == "bank_moving")
        #expect(refused.body["message"]?.stringValue == "Your bank is moving to QBank Cloud, so it cannot change until the move ends. Nothing was changed.")
        #expect(throws: StoreError.writesHeld) {
            try harness.store.run("DELETE FROM course")
        }
        let read = try await harness.send("GET", "/api/semesters")
        #expect(read.status == 200)
        #expect(read.body["topics"]?.arrayValue?.count == 1)
        #expect(try ArchiveWorld.dump(harness.store) == rows)

        harness.store.releaseWrites()
        #expect(try await harness.send("POST", "/api/topics", .object(["title": .string("Invented History")])).status == 201)
    }

    @Test func aWriteAlreadyRunningFinishesBeforeTheHoldBegins() async throws {
        let store = try LocalStore.inMemory()
        let entered = AsyncStream.makeStream(of: Void.self)
        let writing = Task.detached {
            try store.transaction { transaction in
                entered.continuation.yield()
                Thread.sleep(forTimeInterval: 0.2)
                try StoreFixtures.insertSemester(transaction)
            }
        }
        for await _ in entered.stream { break }
        store.holdWrites()
        try await writing.value
        #expect(try BankArchive.counts(of: store)["semesters"] == 1, "the write that was running when the hold came is kept whole")
        #expect(throws: StoreError.writesHeld) {
            try store.transaction { try StoreFixtures.insertSemester($0, 2) }
        }
    }
}
