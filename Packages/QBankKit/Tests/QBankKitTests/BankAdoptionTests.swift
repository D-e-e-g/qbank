import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// Taking the bank QBank Cloud already holds (`docs/cloud.md`, the hand-over's second row): nothing is
/// uploaded or merged, looking changes nothing on either side, the switch is one write of the record,
/// this phone's bank file stays byte for byte as it was, and the sets QBank Cloud does not hold, by
/// lineage or by file, are the ones offered to add as new sets. Invented data only.
@Suite("Taking QBank Cloud's bank")
struct BankAdoptionTests {
    /// QBank Cloud's bank and this phone's, which came from it and went on apart: the phone replaced one
    /// of QBank Cloud's sets, wrote a set of its own, and imported a file QBank Cloud imported too.
    struct World {
        let root: URL
        let phone: LocalBankHarness
        let record: BankHandoverRecord
        let cloudArchive: Data
        let cloudCounts: BankCounts
        /// The set only this phone has.
        let ownSet: String
        let topic: String

        static func make() async throws -> World {
            let cloud = try LocalBankHarness()
            let topic = try #require(try await cloud.send("POST", "/api/topics", .object(["title": .string("Geography")])).body["id"]?.stringValue)
            _ = try await cloud.importFile(Files.make("Capitals", [Files.single("C1"), Files.single("C2")]), into: topic, folderName: "Europe")

            let root = StoreFixtures.temporaryDirectory()
            let phone = LocalBankHarness(store: try LocalStore.open(key: MoveWorld.key, in: root), idPrefix: "ff000000")
            try BankArchive.read(try BankArchive.write(from: cloud.store, at: ArchiveWorld.date), into: phone.store)
            let replaced = try await phone.importFile(Files.make("Capitals", [Files.single("C1"), Files.single("C3")]), into: topic, folderName: "Europe", decision: "replace")
            #expect(replaced.status == 201)
            let own = try await phone.importFile(Files.make("Rivers", [Files.single("R1")]), into: topic, folderName: "Europe")
            let ownSet = try #require(own.body["setId"]?.stringValue)
            let both = Files.make("Mountains", [Files.single("M1")])
            #expect(try await phone.importFile(both, into: topic, folderName: "Asia").status == 201)
            #expect(try await cloud.importFile(both, into: topic, folderName: "Asia").status == 201)

            return World(
                root: root, phone: phone, record: try BankHandoverRecord.file(key: MoveWorld.key, in: root),
                cloudArchive: try BankArchive.write(from: cloud.store, at: ArchiveWorld.date), cloudCounts: try BankArchive.counts(of: cloud.store),
                ownSet: ownSet, topic: topic)
        }

        var file: URL { root.appendingPathComponent("Banks/\(MoveWorld.key)/bank.sqlite") }

        func bytes() throws -> Data { try Data(contentsOf: file) }

        func adoption(_ cloud: DownloadStandIn) -> BankAdoption {
            let client = QBankClient(
                configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
                sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
            return BankAdoption(store: phone.store, record: record, clock: { MoveWorld.start }) { () throws(QBankError) in try await client.downloadBank() }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func lookingReadsQBankCloudsBankAndChangesNothingOnEitherSide() async throws {
        let world = try await World.make()
        defer { world.remove() }
        let before = try world.bytes()
        let cloud = DownloadStandIn(.sends(world.cloudArchive))

        let finding = try await world.adoption(cloud).look().get()

        #expect(finding.counts == world.cloudCounts)
        #expect(finding.cloudHasBank)
        #expect(finding.onlyOnPhone.map(\.id) == [world.ownSet], "a replaced set and a file both sides imported are in QBank Cloud already")
        let own = try #require(finding.onlyOnPhone.first)
        #expect(own.title == "Rivers")
        #expect(own.place == .init(kind: .topic, code: "", title: "Geography", semesterNumber: nil, folder: "Europe"))
        #expect(cloud.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["GET /api/me/bank"], "nothing is sent up")
        #expect(try world.bytes() == before)
        #expect(try world.record.load() == .onPhone)
        #expect(world.record.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == false, "no record is written")
        #expect(!world.phone.store.holdsWrites)
    }

    @Test func takingQBankCloudsBankIsOneWriteOfTheRecordAndTheFileStaysTheSafetyCopy() async throws {
        let world = try await World.make()
        defer { world.remove() }
        let before = try world.bytes()
        let adoption = world.adoption(DownloadStandIn(.sends(world.cloudArchive)))
        let finding = try await adoption.look().get()

        #expect(try adoption.adopt(finding).get() == MoveWorld.start)

        #expect(try world.record.load() == BankHandover.onPhone.inCloud(since: MoveWorld.start, offering: [world.ownSet]))
        #expect(try world.bytes() == before)
        #expect(world.phone.store.holdsWrites, "the safety copy takes no write")
        #expect(try await world.phone.send("POST", "/api/topics", .object(["title": .string("Written after")])).status == 409)
        #expect(try world.bytes() == before)
    }

    @Test func theSetsOfferedAreReadAgainAtTheSwitch() async throws {
        let world = try await World.make()
        defer { world.remove() }
        let adoption = world.adoption(DownloadStandIn(.sends(world.cloudArchive)))
        let finding = try await adoption.look().get()
        // A set written while the person read what taking QBank Cloud's bank means.
        let late = try await world.phone.importFile(Files.make("Lakes", [Files.single("L1")]), into: world.topic, folderName: "Europe")
        let lateSet = try #require(late.body["setId"]?.stringValue)

        _ = try adoption.adopt(finding).get()

        #expect(try world.record.load().offeredSets == [world.ownSet, lateSet], "in the order the folder lists them")
    }

    @Test(arguments: [
        DownloadStandIn.Behavior.fails(.notConnectedToInternet), .fails(.networkConnectionLost), .answers(503, #"{"error":"auth_unavailable","message":"Down."}"#),
        .sends(Data("{".utf8)), .sends(Data(#"{"format":"something else"}"#.utf8)),
    ])
    func aLookThatFailsChangesNothing(_ behavior: DownloadStandIn.Behavior) async throws {
        let world = try await World.make()
        defer { world.remove() }
        let before = try world.bytes()

        let result = await world.adoption(DownloadStandIn(behavior)).look()

        guard case .failure(let failure) = result else {
            Issue.record("found \(result)")
            return
        }
        switch failure {
        case .notDownloaded, .notReadable: break
        default: Issue.record("\(failure)")
        }
        #expect(try world.bytes() == before)
        #expect(try world.record.load() == .onPhone)
    }

    @Test func aBankAlreadyInCloudOrMovingIsNotTakenAgain() async throws {
        let world = try await World.make()
        defer { world.remove() }
        let adoption = world.adoption(DownloadStandIn(.sends(world.cloudArchive)))
        let finding = try await adoption.look().get()
        let leased = BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start))
        try world.record.save(leased)
        #expect(adoption.adopt(finding) == .failure(.moving))
        #expect(try world.record.load() == leased)
        try world.record.save(BankHandover.onPhone.inCloud(since: MoveWorld.start))
        #expect(adoption.adopt(finding) == .failure(.alreadyInCloud))
    }

    @Test func anEmptyQBankCloudHasNoBank() async throws {
        let world = try await World.make()
        defer { world.remove() }
        let empty = try BankArchive.write(from: try LocalStore.inMemory(), at: ArchiveWorld.date)
        let finding = try await world.adoption(DownloadStandIn(.sends(empty))).look().get()
        #expect(!finding.cloudHasBank)
        #expect(finding.onlyOnPhone.count == 3, "every current set of this phone is only here")
    }

    @Test func aPhoneWithNoBankTakesQBankCloudsWithoutMakingAFile() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try !LocalStore.exists(key: MoveWorld.key, in: root))
        let record = try BankHandoverRecord.file(key: MoveWorld.key, in: root)

        try BankAdoption.adoptWithNoBankHere(record: record, at: MoveWorld.start)

        #expect(try record.load() == BankHandover.onPhone.inCloud(since: MoveWorld.start))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Banks/\(MoveWorld.key)").path)
        #expect(names == ["handover.json"], "no bank file is made")
        #expect(try LocalStore.exists(key: MoveWorld.key, in: root), "the person has a record on this phone now")
    }
}
