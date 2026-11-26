import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// Moving the bank on this phone to QBank Cloud (`docs/cloud.md`, the hand-over): the whole bank goes
/// up as one archive, through the real client, and the switch to QBank Cloud happens only once the
/// server's counts equal the phone's in every table. Whatever else happens, the bank on this phone
/// stays the authority, its file is byte for byte as it was, and the lease is given back. The server
/// is a stand-in that stores an archive as `PUT /api/me/bank` does. Invented data only.
@Suite("Moving the bank to QBank Cloud")
struct BankMoveToCloudTests {
    // MARK: A move that works

    @Test func theWholeBankGoesUpAndTheSwitchWaitsForEveryTableToMatch() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let counts = try BankArchive.counts(of: world.store)
        let rows = try ArchiveWorld.dump(world.store)
        let cloud = CloudStandIn(.stores)
        let steps = StepLog()

        let outcome = await world.move(to: cloud).run { await steps.add($0) }

        // The clock is read for the lease, the archive and the switch.
        let movedAt = MoveWorld.start.addingTimeInterval(2)
        #expect(outcome == .moved(counts, at: movedAt))
        #expect(await steps.all == [.writing, .sending, .checking])
        #expect(cloud.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == ["PUT /api/me/bank"])
        let inCloud = try #require(cloud.bank)
        #expect(try ArchiveWorld.dump(inCloud) == rows, "QBank Cloud holds every row of every table")
        #expect(try world.record.load() == BankHandover(authority: .cloud, movedToCloudAt: movedAt))
        #expect(try world.bankBytes() == before, "the bank file is kept as it was, the safety copy")
        #expect(world.store.holdsWrites, "the safety copy takes no write after the switch")
        #expect(try await world.writeATopic() == 409)
        #expect(try world.bankBytes() == before)
    }

    @Test func anEmptyBankMovesToo() async throws {
        let world = try await MoveWorld.make(filled: false)
        defer { world.remove() }
        let outcome = await world.move(to: CloudStandIn(.stores)).run()
        guard case .moved(let counts, _) = outcome else {
            Issue.record("not moved: \(outcome)")
            return
        }
        #expect(counts.values.values.allSatisfy { $0 == 0 })
        #expect(try world.record.load().authority == .cloud)
    }

    // MARK: A move that does not

    /// Every way an upload can end without QBank Cloud's confirmation that it holds the whole bank:
    /// it fails, times out, is refused, or half-succeeds (stored, with an answer that is lost, cannot be
    /// read, or does not count every table).
    static let unstored: [(String, CloudStandIn.Behavior)] = [
        ("no connection", .fails(.notConnectedToInternet)),
        ("a timeout", .fails(.timedOut)),
        ("stored, then the connection dropped", .storesThenFails(.networkConnectionLost)),
        ("stored, then a timeout", .storesThenFails(.timedOut)),
        ("stored, then an answer that is not JSON", .storesThenAnswers(200, { _ in "<html>proxy</html>" })),
        ("stored, then counts that leave a table out", .storesThenAnswers(200, { _ in #"{"counts":{"semesters":1}}"# })),
        ("stored, then a server error", .storesThenAnswers(502, { _ in #"{"error":"bad_gateway","message":"QBank is busy."}"# })),
        ("a server error", .answers(503, #"{"error":"unavailable","message":"QBank is busy. Try again later."}"#)),
        ("an account with a bank", .answers(409, #"{"error":"bank_not_empty","message":"This account already has a question bank on the server, so the upload was refused. Nothing was changed."}"#)),
        ("ids another account has", .answers(409, #"{"error":"bank_ids_taken","message":"Part of this bank is already on the server, in another account. Nothing was changed."}"#)),
        ("no Cloud", .answers(403, #"{"error":"cloud_required","message":"This needs Cloud. Your question bank is on this device."}"#)),
        ("an archive the server refuses", .answers(400, #"{"error":"invalid_archive","message":"This is not a bank archive QBank can store. Nothing was changed.","problems":["questions.0.type: invalid"]}"#)),
        ("an archive too large", .answers(413, #"{"error":"archive_too_large","message":"This bank is larger than QBank takes at once (64 MB). Nothing was changed."}"#)),
        ("a session that ended", .answers(401, #"{"error":"unauthenticated","message":"Sign in to continue."}"#)),
    ]

    @Test(arguments: unstored.map(\.0))
    func anUploadWithoutConfirmationLeavesTheBankOnThisPhoneUnchanged(_ name: String) async throws {
        let behavior = try #require(Self.unstored.first { $0.0 == name }?.1)
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()

        let outcome = await world.move(to: CloudStandIn(behavior)).run()

        guard case .failed(.notStored, leaseReleased: true) = outcome else {
            Issue.record("\(name): \(outcome)")
            return
        }
        try expectOnThisPhone(world, unchangedFrom: before)
    }

    @Test func countsThatDifferInOneTableLeaveTheBankOnThisPhoneUnchanged() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let counts = try BankArchive.counts(of: world.store)
        let answers = try #require(counts["attempts"])
        let short = CloudStandIn(
            .storesThenAnswers(200) { stored in
                var values = stored.values
                values["attempts"] = answers - 1
                return #"{"counts":\#((try? CloudStandIn.text(BankCounts(values)!)) ?? "")}"#
            })

        let outcome = await world.move(to: short).run()

        #expect(outcome == .failed(.countsDiffer([.init(table: "attempts", onPhone: answers, inCloud: answers - 1)]), leaseReleased: true))
        try expectOnThisPhone(world, unchangedFrom: before)
    }

    @Test func countsOfAnotherBankLeaveTheBankOnThisPhoneUnchanged() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let empty = try #require(BankCounts(Dictionary(uniqueKeysWithValues: BankArchive.tableKeys.map { ($0, 0) })))
        let other = CloudStandIn(.answers(200, #"{"counts":\#(try CloudStandIn.text(empty))}"#))

        let outcome = await world.move(to: other).run()

        guard case .failed(.countsDiffer(let differences), leaseReleased: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(differences.map(\.table) == BankArchive.tableKeys, "every table of this bank has rows, and Cloud answered none")
        try expectOnThisPhone(world, unchangedFrom: before)
    }

    // MARK: The lease

    @Test func theLeaseIsOnDiskBeforeTheBankIsReadAndHoldsEveryWriteUntilTheMoveEnds() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let cloud = CloudStandIn(.waits)
        let move = world.move(to: cloud)
        let running = Task { await move.run() }
        await cloud.waitForRequest()

        // What the next launch would find if the app were closed now.
        let relaunched = try world.relaunched()
        let found = try relaunched.record.load()
        #expect(found.authority == .phone)
        #expect(found.lease == BankHandover.Lease(direction: .toCloud, startedAt: MoveWorld.start))
        relaunched.store.close()
        #expect(world.store.holdsWrites)
        #expect(try await world.writeATopic() == 409, "a write while the bank moves is refused")
        #expect(try world.bankBytes() == before)

        cloud.finish(with: .fails(.networkConnectionLost))
        #expect(await running.value == .failed(.notStored(.transport(.networkConnectionLost)), leaseReleased: true))
        try expectOnThisPhone(world, unchangedFrom: before)
    }

    @Test func aMoveTheAppWasClosedDuringIsFinishedByTheNextLaunch() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        // The app was closed after it took the lease: the lease is all that is left of the move.
        try world.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start)))
        world.store.close()
        let relaunched = try world.relaunched()
        #expect(try relaunched.record.load().lease != nil, "the lease outlasts the app")
        #expect(try relaunched.bankBytes() == before)

        let outcome = await relaunched.move(to: CloudStandIn(.stores)).run()

        guard case .moved = outcome else {
            Issue.record("not moved: \(outcome)")
            return
        }
        #expect(try relaunched.record.load().lease == nil)
        #expect(try relaunched.record.load().authority == .cloud)
        #expect(try relaunched.bankBytes() == before)
    }

    @Test func aMoveTheAppWasClosedDuringThatFailsAtTheNextLaunchGivesTheLeaseBack() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        try world.record.save(BankHandover.onPhone.leased(.init(direction: .toCloud, startedAt: MoveWorld.start)))
        world.store.close()
        let relaunched = try world.relaunched()

        let outcome = await relaunched.move(to: CloudStandIn(.fails(.notConnectedToInternet))).run()

        #expect(outcome == .failed(.notStored(.transport(.notConnectedToInternet)), leaseReleased: true))
        try expectOnThisPhone(relaunched, unchangedFrom: before)
    }

    @Test func aLeaseThatCannotBeRecordedStartsNoMove() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        // The record's folder takes no new file.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.folder.path)
        let cloud = CloudStandIn(.stores)

        let outcome = await world.move(to: cloud).run()

        guard case .failed(.notStarted, leaseReleased: true) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(cloud.requests.isEmpty, "nothing is read or sent without the lease")
        #expect(!world.store.holdsWrites)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.folder.path)
        try expectOnThisPhone(world, unchangedFrom: before)
    }

    @Test func aSwitchThatCannotBeRecordedKeepsTheBankOnThisPhoneAndItsLeaseForTheNextLaunch() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let before = try world.bankBytes()
        let cloud = CloudStandIn(.waits)
        let running = Task { await world.move(to: cloud).run() }
        await cloud.waitForRequest()
        // The phone can no longer write the record, as on a full disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.folder.path)
        cloud.finish(with: .stores)

        let outcome = await running.value

        guard case .failed(.switchNotRecorded, leaseReleased: false) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.folder.path)
        let left = try world.record.load()
        #expect(left.authority == .phone, "the bank on this phone stays the authority")
        #expect(left.lease != nil, "the next launch finds the move and deals with it")
        #expect(!world.store.holdsWrites)
        #expect(try world.bankBytes() == before)
    }

    @Test func aBankAlreadyInCloudIsNotMovedAgain() async throws {
        let world = try await MoveWorld.make()
        defer { world.remove() }
        let moved = BankHandover(authority: .cloud, movedToCloudAt: MoveWorld.start)
        try world.record.save(moved)
        let cloud = CloudStandIn(.stores)

        #expect(await world.move(to: cloud).run() == .failed(.alreadyInCloud, leaseReleased: true))
        #expect(cloud.requests.isEmpty)
        #expect(try world.record.load() == moved)
        #expect(!world.store.holdsWrites)
    }

    @Test func differencesNameEachTableThatDoesNotMatchInTheArchivesOrder() throws {
        let base = Dictionary(uniqueKeysWithValues: BankArchive.tableKeys.map { ($0, 2) })
        let phone = try #require(BankCounts(base))
        var cloud = base
        cloud["questions"] = 1
        cloud["semesters"] = 3
        let differences = BankMoveToCloud.differences(onPhone: phone, archived: phone, inCloud: try #require(BankCounts(cloud)))
        #expect(differences == [.init(table: "semesters", onPhone: 2, inCloud: 3), .init(table: "questions", onPhone: 2, inCloud: 1)])
        var written = base
        written["attempts"] = 1
        let changed = BankMoveToCloud.differences(onPhone: phone, archived: try #require(BankCounts(written)), inCloud: phone)
        #expect(changed == [.init(table: "attempts", onPhone: 2, inCloud: 2)], "a bank that changed after its archive was written does not switch")
        #expect(BankMoveToCloud.differences(onPhone: phone, archived: phone, inCloud: phone).isEmpty)
    }

    // MARK: Helpers

    /// The bank on this phone is still the authority, with no move under way, takes writes again, and
    /// its file is byte for byte `before`.
    private func expectOnThisPhone(_ world: MoveWorld, unchangedFrom before: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try world.record.load() == .onPhone, sourceLocation: sourceLocation)
        #expect(try world.bankBytes() == before, "the bank file is byte for byte as it was", sourceLocation: sourceLocation)
        #expect(!world.store.holdsWrites, "the bank takes writes again", sourceLocation: sourceLocation)
    }
}

/// The steps a move told, in order.
actor StepLog {
    private(set) var all: [BankMoveToCloud.Step] = []
    func add(_ step: BankMoveToCloud.Step) { all.append(step) }
}
