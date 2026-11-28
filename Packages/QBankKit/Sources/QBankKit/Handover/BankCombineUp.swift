import Foundation

/// Combines the bank on this phone with the bank QBank Cloud already holds for the account, and makes
/// that one bank the one in use: combine up in `docs/cloud.md`, for an account whose Cloud is active,
/// whose record says the bank is this phone's, and whose server holds a bank (a second device with a
/// bank of its own, a returning subscriber, an upload whose answer was lost).
///
/// In order, and stopping at the first step that fails:
///
/// 1. The lease is recorded beside the bank, marked as a combine's, before the bank is read, and the
///    bank holds its writes, so nothing changes it meanwhile. A lease found at launch is a combine the
///    app was closed during, and it runs again.
/// 2. QBank Cloud's bank is downloaded whole, with its stamp.
/// 3. The bank on this phone is read, and only read, and combined with it in a scratch store
///    (`BankCombine`), which checks that every row of both is there (A), that the numbers add up (B),
///    and that progress agrees with the answers (C).
/// 4. The combined bank is sent with the stamp. The server stores it only while its own bank still has
///    that stamp and the combined one holds every row of it, removes nothing, and answers its counts.
/// 5. Check D: the server's counts are compared with the combined bank's, table by table: all twelve
///    must be equal.
/// 6. Only then is the switch recorded: the authority becomes QBank Cloud's and the lease goes with the
///    same write. The bank file stays exactly as it was, the safety copy, and keeps its writes held.
///
/// A `bank_changed` refusal means another device wrote to QBank Cloud's bank meanwhile: the combine
/// starts again at step 2, up to `tries` times in all. Whatever else fails, the authority stays the
/// phone's, the record is as it was with no lease, and the bank takes writes again. Nothing here
/// writes the bank file. A failure before the server stores the combined bank changes nothing anywhere;
/// one after it (counts that differ, a switch that cannot be recorded) leaves QBank Cloud holding the
/// phone's rows beside its own, which a later combine finds there and does not add again.
public struct BankCombineUp: Sendable {
    /// What the combine is doing, for the screen that shows it.
    public enum Step: Sendable, Equatable {
        /// Downloading QBank Cloud's bank.
        case reading
        /// Combining it with the bank on this phone, and checking the result.
        case combining
        /// Sending the combined bank to QBank Cloud and waiting for the server to store it.
        case sending
        /// Comparing what QBank Cloud holds with the combined bank, table by table.
        case checking
    }

    /// Why a combine did not switch the bank to QBank Cloud. In every case the bank on this phone is
    /// still the authority, and its file was not written to.
    public enum Failure: Error, Sendable, Equatable {
        /// The record beside the bank could not be read or written, so the combine did not begin.
        case notStarted(StoreError)
        /// The record says the bank is QBank Cloud's already, so there is nothing to combine.
        case alreadyInCloud
        /// QBank Cloud's bank did not arrive whole: no connection, a timeout, a refusal, or an answer
        /// that cannot be read.
        case notDownloaded(QBankError)
        /// The two banks could not be combined, or the combined one failed a check: what arrived is not
        /// a bank archive this phone can read, the bank on this phone could not be read, or a rule broke.
        case notCombined(String)
        /// The combined bank did not come back as stored: no connection, a timeout, a refusal from the
        /// server, or an answer that cannot be read.
        case notStored(QBankError)
        /// The server answered with counts that are not the combined bank's.
        case countsDiffer([BankMoveToCloud.Difference])
        /// Everything matched, but this phone could not record the switch, so it keeps its own bank.
        case switchNotRecorded(StoreError)
    }

    public enum Outcome: Sendable {
        /// The bank is QBank Cloud's, since `at`: the combined bank, of `counts`, that `ledger` describes.
        case combined(BankCombine.Ledger, counts: BankCounts, at: Date)
        /// The bank stays on this phone. `leaseReleased` is false only when the lease could not be
        /// given back, which leaves it for the next launch to deal with.
        case failed(Failure, leaseReleased: Bool)
    }

    /// How many times a combine is built and sent before a `bank_changed` refusal ends it.
    public static let tries = 3

    private let store: LocalStore
    private let record: BankHandoverRecord
    private let receipts: BankCombineReceipts
    private let clock: @Sendable () -> Date
    private let download: @Sendable () async throws(QBankError) -> Data
    private let send: @Sendable (Data) async throws(QBankError) -> BankCombined

    /// - Parameters:
    ///   - bank: The bank on this phone.
    ///   - record: Its hand-over record, beside it, where the receipt of the combine is kept too.
    ///   - clock: Where the lease, the combine and the switch read the time.
    ///   - download: QBank Cloud's whole bank, as `QBankClient.downloadBank()` gives it.
    ///   - send: Stores a combined bank in QBank Cloud and answers what it holds then, as
    ///     `QBankClient.combineBank(_:)` does.
    public init(
        bank: LocalBank, record: BankHandoverRecord, clock: @escaping @Sendable () -> Date = { Date() },
        download: @escaping @Sendable () async throws(QBankError) -> Data, send: @escaping @Sendable (Data) async throws(QBankError) -> BankCombined
    ) {
        store = bank.store
        self.record = record
        receipts = BankCombineReceipts(beside: record)
        self.clock = clock
        self.download = download
        self.send = send
    }

    /// Runs the combine, telling `progress` each step as it starts. It reads the bank's file away from
    /// the caller's actor, since a bank can be large.
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
            try record.save(before.leased(BankHandover.Lease(direction: .toCloud, startedAt: clock(), combines: true)))
        } catch {
            return .failed(.notStarted(error), leaseReleased: true)
        }
        store.holdWrites()
        switch await combine(progress, from: before) {
        case .success(let combined):
            return combined
        case .failure(let failure):
            // The authority stays the phone's: the record is as it was before, with no lease.
            let released = (try? record.save(before.leased(nil))) != nil
            store.releaseWrites()
            return .failed(failure, leaseReleased: released)
        }
    }

    /// Lets go of a combine up the app was closed during, without running it, as while combining is
    /// paused: the record is written back with no lease, the bank still this phone's, and the bank takes
    /// writes again. Returns whether there was one. A record with no such lease is left as it is.
    @discardableResult
    public static func letGoLeftOpen(record: BankHandoverRecord, bank: LocalBank) throws(StoreError) -> Bool {
        let found = try record.load()
        guard found.authority == .phone, let lease = found.lease, lease.direction == .toCloud, lease.combines else { return false }
        try record.save(found.leased(nil))
        bank.store.releaseWrites()
        return true
    }

    /// Steps 2 to 6, with the lease taken and writes held.
    private func combine(_ progress: @Sendable (Step) async -> Void, from before: BankHandover) async -> Result<Outcome, Failure> {
        var phone: Data?
        var tries = 0
        while true {
            tries += 1
            await progress(.reading)
            let held: Data
            do {
                held = try await download()
            } catch {
                return .failure(.notDownloaded(error))
            }
            await progress(.combining)
            let combined: BankCombine.Result
            do {
                // The bank on this phone takes no writes, so one snapshot of it serves every try.
                let snapshot = try phone ?? BankArchive.write(from: store, at: clock())
                phone = snapshot
                combined = try BankCombine.combine(phone: snapshot, server: held, at: clock())
            } catch {
                return .failure(.notCombined(String(describing: error)))
            }
            await progress(.sending)
            let stored: BankCombined
            do {
                stored = try await send(combined.archive)
            } catch {
                if error.serverCode == .bankChanged, tries < Self.tries { continue }
                return .failure(.notStored(error))
            }
            let combinedAt = clock()
            // Kept once QBank Cloud stored it, whether the switch follows or not.
            try? receipts.save(BankCombineReceipt(direction: .up, combinedAt: combinedAt, serverStamp: combined.stamp, ledger: combined.ledger, counts: combined.counts))
            await progress(.checking)
            let differences = BankMoveToCloud.differences(onPhone: combined.counts, archived: combined.counts, inCloud: stored.counts)
            guard differences.isEmpty else { return .failure(.countsDiffer(differences)) }
            do {
                // The bank file stays the record's own, the safety copy, as after a move.
                try record.save(before.inCloud(since: combinedAt))
            } catch {
                return .failure(.switchNotRecorded(error))
            }
            return .success(.combined(combined.ledger, counts: combined.counts, at: combinedAt))
        }
    }
}
