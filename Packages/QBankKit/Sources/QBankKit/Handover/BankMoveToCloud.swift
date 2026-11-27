import Foundation

/// Moves the bank on this phone to QBank Cloud: the hand-over's first row in `docs/cloud.md`, for an
/// account whose Cloud the server says is active and whose server holds no bank yet.
///
/// In order, and stopping at the first step that fails:
///
/// 1. The lease is recorded beside the bank, before the bank is read, and the bank holds its writes,
///    so nothing changes it while it moves. A lease found at launch is a move the app was closed during.
/// 2. The bank is written as one bank archive and its counts are read, from the same unchanging bank.
/// 3. The archive is uploaded whole. The server stores it in one transaction, only into an account
///    with no bank, and answers the counts it read back.
/// 4. The server's counts are compared with the counts read again from the bank on this phone, and
///    with the archive's, table by table: all twelve must be equal.
/// 5. Only then is the switch recorded: the authority becomes QBank Cloud and the lease goes with the
///    same write. The bank file stays exactly as it was, as the safety copy, and keeps its writes held.
///
/// Whatever fails, the authority stays the phone's, the bank file is not written to, the lease is
/// given back and the bank takes writes again. Nothing here deletes, moves or rewrites the bank file:
/// the move only reads it.
public struct BankMoveToCloud: Sendable {
    /// What the move is doing, for the screen that shows it.
    public enum Step: Sendable, Equatable {
        /// Writing the bank on this phone as one archive.
        case writing
        /// Sending it to QBank Cloud and waiting for the server to store it.
        case sending
        /// Comparing what QBank Cloud holds with this phone's bank, table by table.
        case checking
    }

    /// A table the server and this phone number differently after an upload.
    public struct Difference: Sendable, Equatable {
        /// The table's archive key, such as `attempts`.
        public let table: String
        public let onPhone: Int
        public let inCloud: Int

        public init(table: String, onPhone: Int, inCloud: Int) {
            self.table = table
            self.onPhone = onPhone
            self.inCloud = inCloud
        }
    }

    /// Why a move did not switch the bank to QBank Cloud. In every case the bank on this phone is still
    /// the authority, and its file was not written to.
    public enum Failure: Error, Sendable, Equatable {
        /// The record beside the bank could not be read or written, so the move did not begin.
        case notStarted(StoreError)
        /// The record says the bank is QBank Cloud's already, so there is nothing to move.
        case alreadyInCloud
        /// The bank on this phone could not be read to write or count it.
        case notRead(String)
        /// The upload did not come back as stored: no connection, a timeout, a refusal from the
        /// server, or an answer that cannot be read.
        case notStored(QBankError)
        /// The server answered with counts that are not this phone's.
        case countsDiffer([Difference])
        /// Everything matched, but this phone could not record the switch, so it keeps its own bank.
        case switchNotRecorded(StoreError)
    }

    public enum Outcome: Sendable, Equatable {
        /// The bank is QBank Cloud's: the server holds `counts`, which equal this phone's, since `at`.
        case moved(BankCounts, at: Date)
        /// The bank stays on this phone. `leaseReleased` is false only when the lease could not be
        /// given back, which leaves it for the next launch to deal with.
        case failed(Failure, leaseReleased: Bool)
    }

    private let store: LocalStore
    private let record: BankHandoverRecord
    private let clock: @Sendable () -> Date
    private let upload: @Sendable (Data) async throws(QBankError) -> BankCounts

    /// - Parameters:
    ///   - store: The bank on this phone.
    ///   - record: Its hand-over record, beside it.
    ///   - clock: Where the lease and the switch read the time, and the archive its `exportedAt`.
    ///   - upload: Stores an archive in QBank Cloud and returns the counts the server read back, as
    ///     `QBankClient.uploadBank(_:)` does.
    public init(
        store: LocalStore, record: BankHandoverRecord, clock: @escaping @Sendable () -> Date = { Date() },
        upload: @escaping @Sendable (Data) async throws(QBankError) -> BankCounts
    ) {
        self.store = store
        self.record = record
        self.clock = clock
        self.upload = upload
    }

    /// The move of `bank`, the bank on this phone, whose hand-over record is `record`.
    public init(
        bank: LocalBank, record: BankHandoverRecord, clock: @escaping @Sendable () -> Date = { Date() },
        upload: @escaping @Sendable (Data) async throws(QBankError) -> BankCounts
    ) {
        self.init(store: bank.store, record: record, clock: clock, upload: upload)
    }

    /// Runs the move, telling `progress` each step as it starts. It reads and writes the bank's file
    /// away from the caller's actor, since a bank can be large.
    @concurrent
    public func run(progress: @escaping @Sendable (Step) async -> Void = { _ in }) async -> Outcome {
        let before: BankHandover
        do {
            before = try record.load()
        } catch {
            return .failed(.notStarted(error), leaseReleased: true)
        }
        guard before.authority == .phone else { return .failed(.alreadyInCloud, leaseReleased: true) }
        do {
            try record.save(before.leased(BankHandover.Lease(direction: .toCloud, startedAt: clock())))
        } catch {
            return .failed(.notStarted(error), leaseReleased: true)
        }
        store.holdWrites()
        switch await move(progress, from: before) {
        case .success(let moved):
            return moved
        case .failure(let failure):
            // The authority stays the phone's: the record is as it was before the move, with no lease.
            let released = (try? record.save(before.leased(nil))) != nil
            store.releaseWrites()
            return .failed(failure, leaseReleased: released)
        }
    }

    /// Steps 2 to 5, with the lease taken and writes held.
    private func move(_ progress: @Sendable (Step) async -> Void, from before: BankHandover) async -> Result<Outcome, Failure> {
        await progress(.writing)
        let archive: Data
        let archived: BankCounts
        do {
            archive = try BankArchive.write(from: store, at: clock())
            archived = try BankArchive.counts(of: store)
        } catch {
            return .failure(.notRead(String(describing: error)))
        }
        await progress(.sending)
        let stored: BankCounts
        do {
            stored = try await upload(archive)
        } catch {
            return .failure(.notStored(error))
        }
        await progress(.checking)
        let onPhone: BankCounts
        do {
            onPhone = try BankArchive.counts(of: store)
        } catch {
            return .failure(.notRead(String(describing: error)))
        }
        let differences = Self.differences(onPhone: onPhone, archived: archived, inCloud: stored)
        guard differences.isEmpty else { return .failure(.countsDiffer(differences)) }
        let movedAt = clock()
        do {
            // The bank file stays the record's own, so a bank that came back once keeps its fresh file.
            try record.save(before.inCloud(since: movedAt))
        } catch {
            return .failure(.switchNotRecorded(error))
        }
        return .success(.moved(stored, at: movedAt))
    }

    /// Every table, in the archive's order, where QBank Cloud's count is not this phone's, or this
    /// phone's is not the archive's. A table missing from either side counts as -1, so it differs.
    static func differences(onPhone: BankCounts, archived: BankCounts, inCloud: BankCounts) -> [Difference] {
        BankArchive.tableKeys.compactMap { table in
            let phone = onPhone[table] ?? -1
            let cloud = inCloud[table] ?? -1
            guard phone != cloud || phone != (archived[table] ?? -1) else { return nil }
            return Difference(table: table, onPhone: phone, inCloud: cloud)
        }
    }
}
