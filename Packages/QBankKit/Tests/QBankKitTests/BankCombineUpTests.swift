import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing

@testable import QBankKit

/// Combine up (`docs/cloud.md`, Combining two banks): QBank Cloud's bank comes down with its stamp, the
/// bank on this phone is combined into a scratch store and checked, the result goes up with the stamp,
/// the server's counts are compared with it, and only then does this phone record QBank Cloud as the
/// authority. A `bank_changed` refusal starts again from the download. Whatever else happens, the record
/// is as it was with no lease, the bank file is byte for byte as it was, and the bank takes writes
/// again. Invented data only.
@Suite("Combining the bank on this phone up into QBank Cloud")
struct BankCombineUpTests {
    /// QBank Cloud's bank: a topic the bank on this phone does not have, as the server sends it.
    private static func serverArchive() async throws -> (archive: Data, counts: BankCounts) {
        let harness = LocalBankHarness(store: try LocalStore.inMemory(), idPrefix: "cc000000")
        #expect(try await harness.send("POST", "/api/topics", .object(["title": .string("Kept in QBank Cloud")])).status == 201)
        return (try CombineWorld.archive(harness.store, server: true), try BankArchive.counts(of: harness.store))
    }

    /// The combine up of `world`'s bank through a client of `cloud`, with a clock that starts at
    /// `MoveWorld.start` and moves a second at each read.
    private func combineUp(_ world: MoveWorld, with cloud: CombineStandIn) -> BankCombineUp {
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
        let ticks = Mutex(0)
        return BankCombineUp(
            bank: LocalBank(store: world.store), record: world.record,
            clock: {
                ticks.withLock { tick in
                    defer { tick += 1 }
                    return MoveWorld.start.addingTimeInterval(TimeInterval(tick))
                }
            },
            download: { () throws(QBankError) in try await client.downloadBank() },
            send: { archive throws(QBankError) in try await client.combineBank(archive) })
    }

    // MARK: A combine that works

    @Test func bothBanksGoUpWithTheStampAndTheSwitchWaitsForTheServersCounts() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let phone = try BankArchive.counts(of: world.store)
        let (archive, held) = try await Self.serverArchive()
        let cloud = CombineStandIn(holding: archive)
        let steps = CombineUpSteps()

        let outcome = await combineUp(world, with: cloud).run { await steps.add($0) }

        guard case .combined(let ledger, let counts, let at) = outcome else {
            Issue.record("not combined: \(outcome)")
            return
        }
        #expect(await steps.all == [.reading, .combining, .sending, .checking])
        #expect(cloud.calls == ["GET /api/me/bank", "POST /api/me/bank/combine"])
        #expect(cloud.sentStamps == [CombineWorld.stamp], "the combined bank carries the stamp of the download it was built on")
        for table in BankArchive.tableKeys where table != "studyPlace" {
            #expect(counts[table] == (phone[table] ?? 0) + (held[table] ?? 0), "\(table): the two banks share nothing, so both are whole")
        }
        #expect(try BankArchive.counts(of: try #require(cloud.stored)) == counts, "QBank Cloud holds the combined bank")
        #expect(ledger.server == BankSummary(sets: 0, questions: 0, answers: 0))
        #expect(ledger.phone == (try BankSummary.of(world.store)))
        #expect(try world.record.load() == BankHandover.onPhone.inCloud(since: at))
        #expect(try world.bankBytes() == before, "the bank file is only read: it is the safety copy")
        #expect(world.store.holdsWrites, "the safety copy takes no writes")
        let receipts = try BankCombineReceipts(beside: world.record).all()
        #expect(receipts == [BankCombineReceipt(direction: .up, combinedAt: at, serverStamp: CombineWorld.stamp, ledger: ledger, counts: counts)])
    }

    @Test func aBankThatChangedMeanwhileIsDownloadedAndCombinedAgain() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let cloud = CombineStandIn(holding: try await Self.serverArchive().archive, combine: .changesFirst(1))

        let outcome = await combineUp(world, with: cloud).run()

        guard case .combined = outcome else {
            Issue.record("not combined: \(outcome)")
            return
        }
        #expect(cloud.calls == ["GET /api/me/bank", "POST /api/me/bank/combine", "GET /api/me/bank", "POST /api/me/bank/combine"])
        #expect(cloud.sentStamps == [CombineWorld.stamp, CombineWorld.stamp + "+"], "the second is built on the bank as it changed")
        #expect(try world.record.load().authority == .cloud)
    }

    @Test func aBankThatKeepsChangingEndsTheCombineWithNothingSwitched() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let cloud = CombineStandIn(holding: try await Self.serverArchive().archive, combine: .changesFirst(BankCombineUp.tries))

        let outcome = await combineUp(world, with: cloud).run()

        guard case .failed(.notStored(let error), leaseReleased: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(error.serverCode == .bankChanged)
        #expect(cloud.calls.count == 2 * BankCombineUp.tries)
        #expect(try world.record.load() == .onPhone)
        #expect(!world.store.holdsWrites)
        #expect(try world.bankBytes() == before)
        #expect(cloud.stored == nil)
    }

    // MARK: A combine that does not

    /// Every step a combine can fail at, with what QBank Cloud does there. `stored` when QBank Cloud
    /// stored the combined bank before the failure.
    private static func failures(_ archive: Data) throws -> [(name: String, stored: Bool, cloud: CombineStandIn, failure: @Sendable (BankCombineUp.Failure) -> Bool)] {
        var unstamped = try ArchiveWorld.parsed(archive)
        unstamped["stamp"] = nil
        let refused: (Int, String) -> CombineStandIn = { status, code in
            CombineStandIn(holding: archive, combine: .answers(status, #"{"error":"\#(code)","message":"Nothing was changed."}"#))
        }
        return [
            ("no connection for the download", false, CombineStandIn(holding: archive, download: .fails(.notConnectedToInternet)), { if case .notDownloaded = $0 { true } else { false } }),
            ("a download cut off", false, CombineStandIn(holding: archive, download: .sends(archive.prefix(archive.count / 2))), { if case .notCombined = $0 { true } else { false } }),
            ("a bank with no stamp to build on", false, CombineStandIn(holding: archive, download: .sends(try ArchiveWorld.serialized(unstamped))), { if case .notCombined = $0 { true } else { false } }),
            ("a refusal for a missing row", false, refused(409, "bank_rows_missing"), { if case .notStored = $0 { true } else { false } }),
            ("a refusal for an older row", false, refused(409, "bank_rows_older"), { if case .notStored = $0 { true } else { false } }),
            ("a refused archive", false, refused(400, "invalid_archive"), { if case .notStored = $0 { true } else { false } }),
            ("Cloud that ended", false, refused(403, "cloud_required"), { if case .notStored = $0 { true } else { false } }),
            ("a server error", false, refused(503, "auth_unavailable"), { if case .notStored = $0 { true } else { false } }),
            ("a connection that drops", false, CombineStandIn(holding: archive, combine: .fails(.networkConnectionLost)), { if case .notStored = $0 { true } else { false } }),
            ("counts that differ", true, CombineStandIn(holding: archive, combine: .storesThenMiscounts(table: "attempts")), { if case .countsDiffer = $0 { true } else { false } }),
        ]
    }

    @Test(arguments: 0..<10)
    func aFailureAtEachStepSwitchesNothing(_ index: Int) async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let (name, stored, cloud, isExpected) = try Self.failures(try await Self.serverArchive().archive)[index]

        let outcome = await combineUp(world, with: cloud).run()

        guard case .failed(let failure, leaseReleased: true) = outcome else {
            Issue.record("\(name): \(outcome)")
            return
        }
        #expect(isExpected(failure), "\(name): \(failure)")
        #expect(try world.record.load() == .onPhone, "\(name): the bank on this phone stays the authority, with no lease")
        #expect(!world.store.holdsWrites, "\(name): the bank takes writes again")
        #expect(try world.bankBytes() == before, "\(name): the bank file is as it was")
        #expect((cloud.stored != nil) == stored, "\(name)")
        #expect(try BankCombineReceipts(beside: world.record).all().count == (stored ? 1 : 0), "\(name): a receipt is kept once QBank Cloud stored it")
    }

    @Test func aSwitchThatCannotBeRecordedKeepsTheBankHereAndItsLeaseForTheNextLaunch() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let folder = world.folder
        // The folder takes no more writes once QBank Cloud has stored the combined bank.
        let cloud = CombineStandIn(
            holding: try await Self.serverArchive().archive,
            combine: .storesThen { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) })

        let outcome = await combineUp(world, with: cloud).run()

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        guard case .failed(.switchNotRecorded, leaseReleased: false) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let found = try world.record.load()
        #expect(found.authority == .phone)
        #expect(found.lease?.combines == true, "the next launch finds the combine's lease")
        #expect(cloud.stored != nil, "QBank Cloud holds the phone's rows beside its own, which a later combine does not add again")
    }

    @Test func aBankAlreadyInCloudIsNotCombined() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        try world.record.save(BankHandover.onPhone.inCloud(since: MoveWorld.start))
        let cloud = CombineStandIn(holding: try await Self.serverArchive().archive)

        guard case .failed(.alreadyInCloud, leaseReleased: true) = await combineUp(world, with: cloud).run() else {
            Issue.record("combined a bank in QBank Cloud")
            return
        }
        #expect(cloud.requests.isEmpty)
    }

    // MARK: A combine the app was closed during

    /// The app was closed during a combine up: the next launch finds its lease, with the bank's writes
    /// held, and the whole combine runs again from the download.
    @Test func aCombineTheAppWasClosedDuringRunsAgainFromTheStart() async throws {
        let world = try await MoveWorld.make()
        try world.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start, combines: true)))
        world.store.close()
        let relaunched = try world.relaunched()
        defer { relaunched.remove() }
        relaunched.store.holdWrites()
        let cloud = CombineStandIn(holding: try await Self.serverArchive().archive)

        let outcome = await combineUp(relaunched, with: cloud).run()

        guard case .combined = outcome else {
            Issue.record("not combined: \(outcome)")
            return
        }
        #expect(cloud.calls == ["GET /api/me/bank", "POST /api/me/bank/combine"])
        #expect(try relaunched.record.load().lease == nil)
        #expect(try relaunched.record.load().authority == .cloud)
    }

    /// While combining is paused, a combine the app was closed during is let go of without running: the
    /// bank on this phone stays the authority and takes writes again.
    @Test func aCombineLeftOpenIsLetGoOfWithoutRunning() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let bank = LocalBank(store: world.store)
        try world.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start)))
        #expect(try !BankCombineUp.letGoLeftOpen(record: world.record, bank: bank), "a move's lease is the move's to finish")

        try world.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start, combines: true)))
        world.store.holdWrites()
        #expect(try BankCombineUp.letGoLeftOpen(record: world.record, bank: bank))
        #expect(try world.record.load() == .onPhone)
        #expect(!world.store.holdsWrites)
        #expect(try !BankCombineUp.letGoLeftOpen(record: world.record, bank: bank), "nothing is left to let go of")
    }
}
