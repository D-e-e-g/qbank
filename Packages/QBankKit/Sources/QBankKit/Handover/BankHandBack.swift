import Foundation

/// Brings a store account's bank back from QBank Cloud to this phone once Cloud has ended: the
/// hand-over's third row in `docs/cloud.md`, for a bank whose authority is QBank Cloud's.
///
/// In order, and stopping at the first step that fails:
///
/// 1. A fresh, empty file is made in the bank's folder, under a dated name no file there has, and the
///    lease is recorded beside the bank, naming it. A lease found at launch is a hand-back the app was
///    closed during.
/// 2. The whole bank is downloaded as one bank archive. The server allows this for an account whose
///    Cloud has ended.
/// 3. The archive is read into the fresh file, whole or not at all: the reader checks the document
///    against its own counts, and what it stored against them, inside its transaction.
/// 4. The fresh file is counted again once the write is done and compared with the archive, table by
///    table: all twelve must be equal.
/// 5. The answers this phone was still waiting to send to QBank Cloud are kept in the fresh file
///    (`keepWaitingAnswers`), which records each once, as the server does.
/// 6. Only then is the switch recorded: the authority becomes this phone's, in the fresh file, with the
///    stamp of the bank it took in, and the lease goes with the same write.
///
/// It also combines down (`docs/cloud.md`, Combining two banks): for a phone whose bank is its own and
/// whose account's Cloud is not active, when the server holds a bank this phone has not taken in, as
/// on a new iPhone that signs in to a lapsed account. The same steps, with the bank on this phone's
/// writes held while they run, and that bank, only read, combined with the download before step 3
/// (`BankCombine`, which checks that every row of both is there, that the numbers add up, and that
/// progress agrees with the answers): the fresh file holds the combined bank, and the file that was the
/// bank stays as it was, an earlier copy. Nothing is sent to the server. Its receipt is kept beside the
/// bank once the switch is recorded.
///
/// Whatever fails, the authority stays where it was and the record is as it was before, with no
/// lease. The fresh file, which never became the bank, is taken away: only a file this hand-back made
/// itself, never one that was there before it, so the safety copy and every earlier file stay as they
/// are. Nothing deletes the server's copy: the hand-back only downloads it.
public struct BankHandBack: Sendable {
    /// What the hand-back is doing, for the screen that shows it.
    public enum Step: Sendable, Equatable {
        /// Downloading the bank from QBank Cloud.
        case downloading
        /// Combining it with the bank on this phone, and checking the result, for a combine down.
        case combining
        /// Writing it into a fresh file on this phone.
        case writing
        /// Comparing the fresh file with what QBank Cloud sent, table by table.
        case checking
    }

    /// Why a hand-back did not make this phone the authority, or a combine down did not switch to the
    /// combined bank. In every case the bank in use is still the one it was, and every file that was in
    /// the bank's folder before is as it was.
    public enum Failure: Error, Sendable, Equatable {
        /// The record beside the bank could not be read or written, so the hand-back did not begin.
        case notStarted(StoreError)
        /// The record says the bank is this phone's already, so there is nothing to bring back.
        case alreadyOnPhone
        /// The download did not arrive whole: no connection, a timeout, a refusal, or an answer that
        /// cannot be read.
        case notDownloaded(QBankError)
        /// The download is not a bank archive this phone can store, or the fresh file refused it.
        case notWritten(String)
        /// The fresh file does not hold what QBank Cloud sent.
        case countsDiffer([BankMoveToCloud.Difference])
        /// The answers still waiting to be sent could not be kept in the fresh file.
        case answersNotKept(String)
        /// The download and the bank on this phone could not be combined, or the combined bank failed a
        /// check: the bank on this phone could not be read, or a rule broke.
        case notCombined(String)
        /// Everything matched, but this phone could not record the switch, so QBank Cloud's bank stays in use.
        case switchNotRecorded(StoreError)
    }

    public enum Outcome: Sendable {
        /// The bank is this phone's again, in `store`, which holds `counts`, since `at`. `combined`
        /// describes the combine down that made it, or is nil for a bank that came back whole.
        case returned(BankCounts, store: LocalStore, at: Date, combined: BankCombine.Ledger?)
        /// QBank Cloud's bank stays in use. `leaseReleased` is false only when the record could not be
        /// written back, which leaves the lease for the next launch to let go of.
        case failed(Failure, leaseReleased: Bool)
    }

    private let record: BankHandoverRecord
    private let clock: @Sendable () -> Date
    private let download: @Sendable () async throws(QBankError) -> Data
    private let createFile: @Sendable (String) throws -> LocalStore
    private let removeFile: @Sendable (String) -> Void
    private let keepWaitingAnswers: @Sendable (LocalStore) async throws -> Void
    private let combining: LocalStore?
    private let receipts: BankCombineReceipts

    /// - Parameters:
    ///   - record: The bank's hand-over record.
    ///   - clock: Where the lease, the fresh file's name and the switch read the time.
    ///   - download: The whole bank from QBank Cloud, as `QBankClient.downloadBank()` gives it.
    ///   - createFile: Makes a new, empty bank file of this name in the bank's folder, throwing
    ///     `StoreError.fileExists` when a file of that name is there, as `LocalStore.create(key:in:file:)` does.
    ///   - removeFile: Takes away a file of this name, as `LocalStore.removeUnused(key:in:file:)` does.
    ///     It is asked only for a file `createFile` made in this hand-back, or one a lease named.
    ///   - keepWaitingAnswers: Records in the fresh bank the answers this phone was waiting to send to
    ///     QBank Cloud, throwing when one could not be kept. By default there are none.
    ///   - combining: The bank on this phone, for a combine down: when the record says the bank is this
    ///     phone's and the one from QBank is to be combined with it. Nil for a bank in QBank Cloud.
    public init(
        record: BankHandoverRecord, clock: @escaping @Sendable () -> Date = { Date() }, download: @escaping @Sendable () async throws(QBankError) -> Data,
        createFile: @escaping @Sendable (String) throws -> LocalStore, removeFile: @escaping @Sendable (String) -> Void,
        keepWaitingAnswers: @escaping @Sendable (LocalStore) async throws -> Void = { _ in }, combining: LocalBank? = nil
    ) {
        self.combining = combining?.store
        receipts = BankCombineReceipts(beside: record)
        self.record = record
        self.clock = clock
        self.download = download
        self.createFile = createFile
        self.removeFile = removeFile
        self.keepWaitingAnswers = keepWaitingAnswers
    }

    /// Runs the hand-back, telling `progress` each step as it starts. It reads and writes the bank
    /// away from the caller's actor, since a bank can be large.
    @concurrent
    public func run(progress: @escaping @Sendable (Step) async -> Void = { _ in }) async -> Outcome {
        let found: BankHandover
        do {
            found = try record.load()
        } catch {
            return .failed(.notStarted(error), leaseReleased: true)
        }
        let phone = found.authority == .phone ? combining : nil
        guard found.authority == .cloud || phone != nil else { return .failed(.alreadyOnPhone, leaseReleased: true) }
        phone?.holdWrites()
        let outcome = await run(from: found, combining: phone, progress: progress)
        if case .failed = outcome { phone?.releaseWrites() }
        return outcome
    }

    /// Steps 1 to 6, from the record as it was found.
    private func run(from found: BankHandover, combining phone: LocalStore?, progress: @escaping @Sendable (Step) async -> Void) async -> Outcome {
        // A hand-back the app was closed during is let go of first: its file never became the bank.
        let before = Self.letGo(found, removeFile: removeFile)
        let store: LocalStore
        let file: String
        do {
            (store, file) = try makeFreshFile(besides: before.bankFile)
        } catch {
            let released = before == found || (try? record.save(before)) != nil
            return .failed(.notWritten(String(describing: error)), leaseReleased: released)
        }
        do {
            try record.save(before.leased(BankHandover.Lease(direction: .toPhone, startedAt: clock(), file: file, combines: phone != nil)))
        } catch {
            store.close()
            removeFile(file)
            return .failed(.notStarted(error), leaseReleased: true)
        }
        switch await handBack(into: store, file: file, progress, from: before, combining: phone) {
        case .success(let returned):
            return returned
        case .failure(let failure):
            // QBank Cloud stays the authority: the record is as it was before, with no lease, and the
            // fresh file this hand-back made, which never became the bank, goes.
            store.close()
            removeFile(file)
            let released = (try? record.save(before)) != nil
            return .failed(failure, leaseReleased: released)
        }
    }

    /// Steps 2 to 6, with the fresh file made and the lease taken.
    private func handBack(
        into store: LocalStore, file: String, _ progress: @Sendable (Step) async -> Void, from before: BankHandover, combining phone: LocalStore?
    ) async -> Result<Outcome, Failure> {
        await progress(.downloading)
        var archive: Data
        do {
            archive = try await download()
        } catch {
            return .failure(.notDownloaded(error))
        }
        var combined: BankCombine.Result?
        if let phone {
            await progress(.combining)
            do {
                let result = try BankCombine.combine(phone: BankArchive.write(from: phone, at: clock()), server: archive, at: clock())
                archive = result.archive
                combined = result
            } catch {
                return .failure(.notCombined(String(describing: error)))
            }
        }
        await progress(.writing)
        let sent: BankCounts
        let stamp: String?
        do {
            sent = try BankArchive.read(archive, into: store)
            stamp = try BankArchive.stamp(of: store)
        } catch {
            return .failure(.notWritten(String(describing: error)))
        }
        await progress(.checking)
        let written: BankCounts
        do {
            written = try BankArchive.counts(of: store)
        } catch {
            return .failure(.notWritten(String(describing: error)))
        }
        let differences = BankMoveToCloud.differences(onPhone: written, archived: sent, inCloud: sent)
        guard differences.isEmpty else { return .failure(.countsDiffer(differences)) }
        let counts: BankCounts
        do {
            try await keepWaitingAnswers(store)
            counts = try BankArchive.counts(of: store)
        } catch {
            return .failure(.answersNotKept(String(describing: error)))
        }
        let returnedAt = clock()
        do {
            try record.save(before.onPhone(in: file, since: returnedAt, stamp: stamp))
        } catch {
            return .failure(.switchNotRecorded(error))
        }
        if let combined {
            try? receipts.save(BankCombineReceipt(direction: .down, combinedAt: returnedAt, serverStamp: combined.stamp, ledger: combined.ledger, counts: counts))
        }
        return .success(.returned(counts, store: store, at: returnedAt, combined: combined?.ledger))
    }

    /// A new, empty file under a dated name that no file in the bank's folder has, so nothing that was
    /// there is ever written over or, later, taken away: a name already taken, as after the clock was
    /// set back, moves on by a millisecond.
    private func makeFreshFile(besides bankFile: String) throws -> (LocalStore, String) {
        var date = clock()
        for _ in 0..<1000 {
            let name = StoreFiles.freshFileName(at: date)
            date = date.addingTimeInterval(0.001)
            guard name != bankFile else { continue }
            do {
                return (try createFile(name), name)
            } catch StoreError.fileExists {
                continue
            }
        }
        throw StoreError.fileExists(StoreFiles.freshFileName(at: date))
    }

    /// Lets go of a hand-back or a combine down the app was closed during, as the next launch finds it:
    /// the fresh file it was writing never became the bank, so it is taken away, and the record is
    /// written back with no lease, the bank in use still the one it was. Returns the lease let go of, so
    /// a combine down can run again, or nil when there was none. A record with no such lease is left as
    /// it is.
    @discardableResult
    public static func letGoLeftOpen(record: BankHandoverRecord, removeFile: @Sendable (String) -> Void) throws(StoreError) -> BankHandover.Lease? {
        let found = try record.load()
        guard let lease = found.lease, lease.direction == .toPhone else { return nil }
        try record.save(letGo(found, removeFile: removeFile))
        return lease
    }

    /// `handover` with its hand-back's lease gone and the file that lease named taken away. A lease
    /// names only a file its hand-back made, and never the bank's own file.
    private static func letGo(_ handover: BankHandover, removeFile: @Sendable (String) -> Void) -> BankHandover {
        guard let lease = handover.lease, lease.direction == .toPhone else { return handover }
        if let file = lease.file, file != handover.bankFile { removeFile(file) }
        return handover.leased(nil)
    }
}
