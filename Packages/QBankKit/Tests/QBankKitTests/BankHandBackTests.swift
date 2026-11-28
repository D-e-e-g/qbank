import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// Bringing a bank back from QBank Cloud once Cloud has ended (`docs/cloud.md`, the hand-over): the
/// whole bank comes down as one archive, through the real client, into a fresh file, and this phone
/// becomes the authority only once the fresh file's counts equal the archive's in every table. Whatever
/// else happens, QBank Cloud's bank stays the one in use, the record is as it was with no lease, and
/// every file that was in the bank's folder is byte for byte as it was, with nothing added. Invented
/// data only.
@Suite("Bringing the bank back from QBank Cloud")
struct BankHandBackTests {
    // MARK: A hand-back that works

    @Test func theWholeBankComesDownIntoAFreshFileAndTheSwitchWaitsForEveryTableToMatch() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        let files = try world.files()
        let cloud = DownloadStandIn(.sends(world.cloudArchive))
        let steps = HandBackSteps()

        let outcome = await world.handBack(from: cloud).run { await steps.add($0) }

        guard case .returned(let counts, let store, let returnedAt, nil) = outcome else {
            Issue.record("not returned: \(outcome)")
            return
        }
        #expect(counts == world.cloudCounts)
        #expect(await steps.all == [.downloading, .writing, .checking])
        #expect(cloud.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["GET /api/me/bank"])
        #expect(try ArchiveWorld.dump(store) == world.cloudRows, "the fresh file holds every row of QBank Cloud's bank")
        // The clock is read for the file's name, the lease and the switch.
        let file = StoreFiles.freshFileName(at: HandBackWorld.start)
        #expect(file == "bank-20270115T080000000Z.sqlite")
        #expect(returnedAt == HandBackWorld.start.addingTimeInterval(2))
        #expect(try world.record.load() == world.before.onPhone(in: file, since: returnedAt, stamp: CombineWorld.stamp), "it names the stamp of the bank it took in")
        #expect(try BankCombineReceipts(beside: world.record).all().isEmpty, "a bank that comes back whole is not a combine")
        #expect(store.fileURL?.lastPathComponent == file)
        #expect(!store.holdsWrites, "the bank on this phone takes writes again")
        let after = try world.files()
        for (name, bytes) in files where name != "handover.json" {
            #expect(after[name] == bytes, "\(name), the safety copy, is as it was")
        }
        #expect(Set(after.keys).subtracting(files.keys) == [file])
    }

    // MARK: Combining down

    /// The combine down of `world`'s bank on this phone with QBank's, downloading from `cloud`.
    private func combiningDown(_ world: MoveWorld, from cloud: DownloadStandIn) -> BankHandBack {
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: cloud,
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
        let root = world.root
        return BankHandBack(
            record: world.record, clock: { HandBackWorld.start }, download: { () throws(QBankError) in try await client.downloadBank() },
            createFile: { file in try LocalStore.create(key: MoveWorld.key, in: root, file: file) },
            removeFile: { file in try? LocalStore.removeUnused(key: MoveWorld.key, in: root, file: file) },
            combining: LocalBank(store: world.store))
    }

    /// QBank's bank for a combine down: a topic the bank on this phone does not have, as the server
    /// sends it, with its stamp.
    private func serverBank() async throws -> (archive: Data, store: LocalStore) {
        let harness = LocalBankHarness(store: try LocalStore.inMemory(), idPrefix: "cc000000")
        #expect(try await harness.send("POST", "/api/topics", .object(["title": .string("Kept in QBank")])).status == 201)
        return (try CombineWorld.archive(harness.store, server: true), harness.store)
    }

    @Test func aCombineDownWritesBothBanksIntoAFreshFileAndKeepsTheOneHereAsItWas() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let phone = try BankArchive.counts(of: world.store)
        let (archive, cloud) = try await serverBank()
        let steps = HandBackSteps()

        let outcome = await combiningDown(world, from: DownloadStandIn(.sends(archive))).run { await steps.add($0) }

        guard case .returned(let counts, let store, let at, let combined?) = outcome else {
            Issue.record("not combined: \(outcome)")
            return
        }
        #expect(await steps.all == [.downloading, .combining, .writing, .checking])
        let file = StoreFiles.freshFileName(at: HandBackWorld.start)
        #expect(try world.record.load() == BankHandover.onPhone.onPhone(in: file, since: at, stamp: CombineWorld.stamp), "the record names the bank it took in")
        let held = try BankArchive.counts(of: cloud)
        for table in BankArchive.tableKeys where table != "studyPlace" {
            #expect(counts[table] == (phone[table] ?? 0) + (held[table] ?? 0), "\(table): the two banks share nothing, so both are whole in the fresh file")
        }
        #expect(try BankArchive.counts(of: store) == counts)
        #expect(combined.combined == (try BankSummary.of(store)))
        #expect(try world.bankBytes() == before, "the bank that was here is only read")
        #expect(world.store.holdsWrites, "the earlier bank takes no writes; the fresh one is the bank in use")
        let receipt = try #require(try BankCombineReceipts(beside: world.record).all().first)
        #expect(receipt == BankCombineReceipt(direction: .down, combinedAt: at, serverStamp: CombineWorld.stamp, ledger: combined, counts: counts))
    }

    @Test func aCombineDownThatFailsLeavesTheOneHereInUseAndTakingWrites() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let (archive, _) = try await serverBank()
        var unstamped = try ArchiveWorld.parsed(archive)
        unstamped["stamp"] = nil
        let downloads: [(String, DownloadStandIn.Behavior)] = [
            ("no connection", .fails(.notConnectedToInternet)),
            ("a download cut off", .sends(archive.prefix(archive.count / 2))),
            ("a bank with no stamp to build on", .sends(try ArchiveWorld.serialized(unstamped))),
        ]
        for (name, behavior) in downloads {
            let outcome = await combiningDown(world, from: DownloadStandIn(behavior)).run()

            guard case .failed(let failure, leaseReleased: true) = outcome else {
                Issue.record("\(name): \(outcome)")
                continue
            }
            switch failure {
            case .notDownloaded, .notCombined: break
            default: Issue.record("\(name): \(failure)")
            }
            #expect(try world.record.load() == .onPhone, "\(name)")
            #expect(!world.store.holdsWrites, "\(name)")
            #expect(try world.bankBytes() == before, "\(name)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: world.folder.path).allSatisfy { !$0.hasPrefix("bank-") && !$0.hasPrefix("combine-") }, "\(name)")
        }
    }

    /// The app was closed during a combine down: the next launch lets go of its fresh file, says it was
    /// a combine, and the combine runs again from the start.
    @Test func aCombineDownTheAppWasClosedDuringIsLetGoAndRunsAgain() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let left = "bank-20270115T075900000Z.sqlite"
        try LocalStore.create(key: MoveWorld.key, in: world.root, file: left).close()
        try world.record.save(BankHandover.onPhone.leased(.init(direction: .toPhone, startedAt: HandBackWorld.start, file: left, combines: true)))

        let lease = try BankHandBack.letGoLeftOpen(record: world.record) { try? LocalStore.removeUnused(key: MoveWorld.key, in: world.root, file: $0) }
        #expect(lease?.combines == true)
        #expect(try world.record.load() == .onPhone)
        #expect(!FileManager.default.fileExists(atPath: world.folder.appendingPathComponent(left).path))

        let (archive, _) = try await serverBank()
        guard case .returned(_, _, _, .some) = await combiningDown(world, from: DownloadStandIn(.sends(archive))).run() else {
            Issue.record("the combine did not run again")
            return
        }
        #expect(try world.record.load().bankStamp == CombineWorld.stamp)
    }

    @Test func aBankOnThisPhoneIsNotCombinedWithoutBeingNamed() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: TestClient.baseURL), transport: DownloadStandIn(.fails(.notConnectedToInternet)),
            sessionStore: InMemorySessionStore(StoredSession(token: "synthetic-session-token")))
        let handBack = BankHandBack(
            record: world.record, download: { () throws(QBankError) in try await client.downloadBank() }, createFile: { _ in throw CancellationError() },
            removeFile: { _ in })
        guard case .failed(.alreadyOnPhone, _) = await handBack.run() else {
            Issue.record("not refused")
            return
        }
    }

    @Test func aBankThatComesBackOpensFromItsRecordAtTheNextLaunch() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        guard case .returned(_, let store, _, _) = await world.handBack(from: DownloadStandIn(.sends(world.cloudArchive))).run() else {
            Issue.record("not returned")
            return
        }
        store.close()
        let record = try world.record.load()
        let reopened = try LocalStore.open(key: HandBackWorld.key, in: world.root, file: record.bankFile)
        defer { reopened.close() }
        #expect(try ArchiveWorld.dump(reopened) == world.cloudRows)
    }

    @Test func theAnswersStillWaitingAreKeptInTheFreshFileBeforeTheSwitch() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        let record = world.record
        let seen = Box<(authority: BankHandover.Authority, counts: BankCounts)?>(nil)
        let handBack = world.handBack(from: DownloadStandIn(.sends(world.cloudArchive))) { store in
            seen.set((try record.load().authority, try BankArchive.counts(of: store)))
            try store.transaction { try StoreFixtures.insertSemester($0, 3) }
        }

        let outcome = await handBack.run()

        let kept = try #require(seen.value)
        #expect(kept.authority == .cloud, "the answers are kept before this phone is the authority")
        #expect(kept.counts == world.cloudCounts, "into the checked copy of QBank Cloud's bank")
        guard case .returned(let counts, _, _, _) = outcome else {
            Issue.record("not returned: \(outcome)")
            return
        }
        #expect(counts["semesters"] == (world.cloudCounts["semesters"] ?? 0) + 1, "the counts said are the fresh file's, with what was kept")
    }

    // MARK: A hand-back that does not

    /// Every way the download can end without the whole bank: it fails, half-arrives, is refused, or is
    /// not a bank archive whose rows match its own counts.
    static func undelivered(_ archive: Data) throws -> [(String, DownloadStandIn.Behavior)] {
        var miscounted = try ArchiveWorld.parsed(archive)
        var counts = try #require(miscounted["counts"] as? [String: Int])
        counts["questions"] = (counts["questions"] ?? 0) + 1
        miscounted["counts"] = counts
        var incomplete = try ArchiveWorld.parsed(archive)
        incomplete["complete"] = false
        return [
            ("no connection", .fails(.notConnectedToInternet)),
            ("a timeout", .fails(.timedOut)),
            ("a connection that drops partway", .fails(.networkConnectionLost)),
            ("a server error", .answers(503, #"{"error":"auth_unavailable","message":"Sign-in is not configured."}"#)),
            ("an ended session", .answers(401, #"{"error":"unauthenticated","message":"Sign in to continue."}"#)),
            ("a download cut off", .sends(archive.prefix(archive.count / 2))),
            ("counts that do not match the rows", .sends(try ArchiveWorld.serialized(miscounted))),
            ("an archive that left rows out", .sends(try ArchiveWorld.serialized(incomplete))),
            ("something that is not an archive", .sends(Data(#"{"courses":[]}"#.utf8))),
        ]
    }

    @Test(arguments: 0..<9)
    func aDownloadThatDoesNotArriveWholeChangesNothing(_ index: Int) async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        let (name, behavior) = try Self.undelivered(world.cloudArchive)[index]
        let files = try world.files()

        let outcome = await world.handBack(from: DownloadStandIn(behavior)).run()

        guard case .failed(let failure, leaseReleased: true) = outcome else {
            Issue.record("\(name): \(outcome)")
            return
        }
        switch failure {
        case .notDownloaded, .notWritten: break
        default: Issue.record("\(name): \(failure)")
        }
        #expect(try world.record.load() == world.before, "\(name): QBank Cloud's bank stays the one in use, with no lease")
        #expect(try world.files() == files, "\(name): every file is as it was, and no fresh file is left")
    }

    @Test func answersThatCannotBeKeptChangeNothing() async throws {
        struct NotKept: Error {}
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        let files = try world.files()

        let outcome = await world.handBack(from: DownloadStandIn(.sends(world.cloudArchive))) { _ in throw NotKept() }.run()

        guard case .failed(.answersNotKept, leaseReleased: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(try world.record.load() == world.before)
        #expect(try world.files() == files)
    }

    @Test func aSwitchThatCannotBeRecordedKeepsQBankCloudsBankAndItsLeaseForTheNextLaunch() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        let record = world.record
        let folder = world.folder
        // The folder takes no more writes once the fresh file is checked, so the switch cannot be written.
        let handBack = world.handBack(from: DownloadStandIn(.sends(world.cloudArchive))) { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }

        let outcome = await handBack.run()

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        guard case .failed(.switchNotRecorded, leaseReleased: false) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let found = try record.load()
        #expect(found.authority == .cloud)
        #expect(found.lease?.direction == .toPhone, "the next launch finds the lease and lets go of its file")
        #expect(try BankHandBack.letGoLeftOpen(record: record) { try? LocalStore.removeUnused(key: HandBackWorld.key, in: world.root, file: $0) } != nil)
        #expect(try record.load() == world.before)
        #expect(try world.files().keys.sorted() == ["bank.sqlite", "handover.json"])
    }

    @Test func aBankOnThisPhoneHasNothingToBringBack() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        try world.record.save(.onPhone)
        let files = try world.files()
        let cloud = DownloadStandIn(.sends(world.cloudArchive))

        let outcome = await world.handBack(from: cloud).run()

        guard case .failed(.alreadyOnPhone, leaseReleased: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(cloud.requests.isEmpty)
        #expect(try world.files() == files)
    }

    @Test func aRecordThisAppCannotReadStartsNothing() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        try Data(#"{"authority":"cloud","version":9}"#.utf8).write(to: try #require(world.record.fileURL))
        let files = try world.files()
        let cloud = DownloadStandIn(.sends(world.cloudArchive))

        let outcome = await world.handBack(from: cloud).run()

        guard case .failed(.notStarted(.unreadableHandover), leaseReleased: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(cloud.requests.isEmpty)
        #expect(try world.files() == files)
    }

    // MARK: The fresh file

    @Test func aHandBackTheAppWasClosedDuringIsLetGoAtTheNextLaunchAndRunsAgain() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        let files = try world.files()
        // The app was closed after the fresh file had part of the bank in it.
        let left = "bank-20270115T075900000Z.sqlite"
        let half = try LocalStore.create(key: HandBackWorld.key, in: world.root, file: left)
        try half.transaction { try StoreFixtures.insertSemester($0) }
        half.close()
        try world.record.save(world.before.leased(.init(direction: .toPhone, startedAt: HandBackWorld.start, file: left)))

        let removeFile: @Sendable (String) -> Void = { try? LocalStore.removeUnused(key: HandBackWorld.key, in: world.root, file: $0) }
        #expect(try BankHandBack.letGoLeftOpen(record: world.record, removeFile: removeFile)?.combines == false)
        #expect(try world.record.load() == world.before, "QBank Cloud's bank is still the one in use")
        #expect(try world.files().keys.sorted() == files.keys.sorted(), "the file that never became the bank is gone")
        #expect(try BankHandBack.letGoLeftOpen(record: world.record, removeFile: removeFile) == nil, "nothing is left to let go of")

        guard case .returned = await world.handBack(from: DownloadStandIn(.sends(world.cloudArchive))).run() else {
            Issue.record("the hand-back did not run again")
            return
        }
        #expect(try world.record.load().authority == .phone)
    }

    @Test func aFreshFileNeverTakesTheNameOfAFileThatIsAlreadyThere() async throws {
        let world = try await HandBackWorld.make()
        defer { world.remove() }
        // An earlier safety copy whose name the clock, set back, would give the fresh file.
        let earlier = StoreFiles.freshFileName(at: HandBackWorld.start)
        let copy = try LocalStore.create(key: HandBackWorld.key, in: world.root, file: earlier)
        try copy.transaction { try StoreFixtures.insertSemester($0) }
        copy.close()
        let files = try world.files()

        guard case .failed = await world.handBack(from: DownloadStandIn(.fails(.notConnectedToInternet)), fixedClock: true).run() else {
            Issue.record("the download should fail")
            return
        }
        #expect(try world.files() == files, "a failure takes away only the file it made")

        guard case .returned(_, let store, _, _) = await world.handBack(from: DownloadStandIn(.sends(world.cloudArchive)), fixedClock: true).run() else {
            Issue.record("not returned")
            return
        }
        #expect(store.fileURL?.lastPathComponent == "bank-20270115T080000001Z.sqlite")
        #expect(try world.files()[earlier] == files[earlier], "the earlier file is as it was")
    }

    @Test func freshFileNamesAreDatedAndNoOtherNameIsABankFile() throws {
        #expect(StoreFiles.freshFileName(at: Date(timeIntervalSince1970: 1_795_700_000.123)) == "bank-20261126T133320123Z.sqlite")
        for name in ["bank.sqlite", "bank-20261126T133320123Z.sqlite"] {
            #expect(throws: Never.self) { try StoreFiles.validate(fileName: name) }
        }
        for name in ["../bank.sqlite", "handover.json", "bank-2026.sqlite", "bank-20261126T133320123Z.sqlite-journal", "Bank.sqlite", ""] {
            #expect(throws: StoreError.invalidFileName(name)) { try StoreFiles.validate(fileName: name) }
        }
        #expect(throws: StoreError.invalidFileName("bank.sqlite")) {
            try LocalStore.removeUnused(key: HandBackWorld.key, in: StoreFixtures.temporaryDirectory(), file: "bank.sqlite")
        }
    }

    @Test func aFileAlreadyThereIsNeverMadeAgain() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "bank-20270115T080000000Z.sqlite"
        let first = try LocalStore.create(key: HandBackWorld.key, in: root, file: name)
        try first.transaction { try StoreFixtures.insertSemester($0) }
        first.close()
        #expect(throws: StoreError.fileExists(name)) { _ = try LocalStore.create(key: HandBackWorld.key, in: root, file: name) }
        _ = try LocalStore.open(key: HandBackWorld.key, in: root)
        #expect(throws: StoreError.fileExists(LocalStore.firstFile)) {
            _ = try LocalStore.create(key: HandBackWorld.key, in: root, file: LocalStore.firstFile)
        }
    }

    @Test func aLaterFileThatIsMissingNeverOpensAsAnEmptyBank() throws {
        let root = StoreFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "bank-20270115T080000000Z.sqlite"
        #expect(throws: (any Error).self) { _ = try LocalStore.open(key: HandBackWorld.key, in: root, file: name) }
        let folder = root.appendingPathComponent("Banks").appendingPathComponent(HandBackWorld.key)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "no empty bank is made in its place")
        let first = try LocalStore.open(key: HandBackWorld.key, in: root)
        first.close()
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(LocalStore.firstFile).path), "the first file is made on first use, as before")
    }

    @Test func aFileOpenedToReadStaysByteForByteAsItWasAndTakesNoWrite() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        world.store.close()
        let before = try world.bankBytes()
        let rows = try ArchiveWorld.dump(try LocalStore.readOnly(key: MoveWorld.key, in: world.root, file: LocalStore.firstFile))
        let reader = try LocalStore.readOnly(key: MoveWorld.key, in: world.root, file: LocalStore.firstFile)
        #expect(try ArchiveWorld.dump(reader) == rows)
        #expect(throws: StoreError.writesHeld) { try reader.run("DELETE FROM course") }
        reader.close()
        #expect(try world.bankBytes() == before)
        #expect(throws: (any Error).self) {
            try LocalStore.readOnly(key: MoveWorld.key, in: world.root, file: "bank-20270115T080000000Z.sqlite")
        }
    }
}
