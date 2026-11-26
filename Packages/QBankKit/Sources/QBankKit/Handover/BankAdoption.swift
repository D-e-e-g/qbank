import Foundation

/// Takes the bank QBank Cloud already holds for the account as the one this phone uses: the
/// hand-over's second row in `docs/cloud.md`, for a second device, a returning subscriber, or an
/// upload whose answer was lost.
///
/// QBank Cloud's bank is the authority. Nothing is uploaded and nothing is merged: `look()` downloads
/// QBank Cloud's bank only to read it, and compares its sets with this phone's, changing nothing on
/// either side; `adopt(_:)` is one write of the record beside the bank, after the person has been told
/// what it means. This phone's own bank file is never written to: from then on it is the safety copy,
/// its writes held. Its sets that QBank Cloud does not hold are named in the record, to be offered as
/// new sets in QBank Cloud (`BankOffer`), on the person's word only.
///
/// A set is in QBank Cloud when one of QBank Cloud's sets, of any version, deleted or not, has its
/// lineage, as a set that moved between the two has, or its very file, as the same file imported on
/// each side has.
public struct BankAdoption: Sendable {
    /// What QBank Cloud holds, read without changing anything.
    public struct Finding: Sendable, Equatable {
        /// What QBank Cloud's bank holds, table by table.
        public let counts: BankCounts
        /// What QBank Cloud's bank holds, as the person counts it.
        public let summary: BankSummary
        /// This phone's sets that QBank Cloud does not hold, in the order Home lists them.
        public let onlyOnPhone: [BankOffer.PhoneSet]
        let cloudSets: BankOffer.HeldSets

        /// Whether QBank Cloud holds a bank for the account: a row in any of the twelve tables.
        public var cloudHasBank: Bool { counts.values.values.contains { $0 > 0 } }
    }

    /// Why this phone did not take QBank Cloud's bank. In every case this phone's bank is still the
    /// authority and its file was not written to.
    public enum Failure: Error, Sendable, Equatable {
        /// QBank Cloud's bank did not arrive: no connection, a timeout, a refusal, or an answer that
        /// cannot be read.
        case notDownloaded(QBankError)
        /// What arrived is not a bank archive this phone can read.
        case notReadable(String)
        /// This phone's bank could not be read to compare its sets.
        case notRead(String)
        /// The record beside the bank could not be read, so nothing began.
        case notStarted(StoreError)
        /// The record says the bank is QBank Cloud's already.
        case alreadyInCloud
        /// A move of this phone's bank is under way, so its authority does not change now.
        case moving
        /// Everything was read, but this phone could not record the switch, so it keeps its own bank.
        case switchNotRecorded(StoreError)
    }

    private let store: LocalStore
    private let record: BankHandoverRecord
    private let clock: @Sendable () -> Date
    private let download: @Sendable () async throws(QBankError) -> Data

    /// - Parameters:
    ///   - store: This phone's bank.
    ///   - record: Its hand-over record, beside it.
    ///   - clock: Where the switch reads the time.
    ///   - download: QBank Cloud's whole bank, as `QBankClient.downloadBank()` gives it.
    public init(
        store: LocalStore, record: BankHandoverRecord, clock: @escaping @Sendable () -> Date = { Date() },
        download: @escaping @Sendable () async throws(QBankError) -> Data
    ) {
        self.store = store
        self.record = record
        self.clock = clock
        self.download = download
    }

    /// This phone's bank, `bank`, whose hand-over record is `record`.
    public init(
        bank: LocalBank, record: BankHandoverRecord, clock: @escaping @Sendable () -> Date = { Date() },
        download: @escaping @Sendable () async throws(QBankError) -> Data
    ) {
        self.init(store: bank.store, record: record, clock: clock, download: download)
    }

    /// Downloads QBank Cloud's bank and compares its sets with this phone's. Writes nothing anywhere:
    /// QBank Cloud's bank is read into memory and let go.
    @concurrent
    public func look() async -> Result<Finding, Failure> {
        let archive: Data
        do {
            archive = try await download()
        } catch {
            return .failure(.notDownloaded(error))
        }
        let counts: BankCounts
        let summary: BankSummary
        let cloudSets: BankOffer.HeldSets
        do {
            let cloud = try LocalStore.inMemory()
            defer { cloud.close() }
            counts = try BankArchive.read(archive, into: cloud)
            summary = try BankSummary.of(cloud)
            cloudSets = try cloud.read { try BankOffer.heldSets(in: $0) }
        } catch {
            return .failure(.notReadable(String(describing: error)))
        }
        do {
            let onlyOnPhone = try BankOffer.sets(of: store, notIn: cloudSets)
            return .success(Finding(counts: counts, summary: summary, onlyOnPhone: onlyOnPhone, cloudSets: cloudSets))
        } catch {
            return .failure(.notRead(String(describing: error)))
        }
    }

    /// Records that QBank Cloud's bank, as `finding` read it, is the one this phone uses from now on,
    /// and holds this phone's bank's writes: its file stays as it is, the safety copy. The sets offered
    /// are this phone's sets that QBank Cloud does not hold, read again now. Returns when the switch is
    /// dated.
    public func adopt(_ finding: Finding) -> Result<Date, Failure> {
        let before: BankHandover
        do {
            before = try record.load()
        } catch {
            return .failure(.notStarted(error))
        }
        guard before.authority == .phone else { return .failure(.alreadyInCloud) }
        guard before.lease == nil else { return .failure(.moving) }
        let offered: [String]
        do {
            offered = try BankOffer.sets(of: store, notIn: finding.cloudSets).map(\.id)
        } catch {
            return .failure(.notRead(String(describing: error)))
        }
        let adoptedAt = clock()
        store.holdWrites()
        do {
            try record.save(before.inCloud(since: adoptedAt, offering: offered))
        } catch {
            store.releaseWrites()
            return .failure(.switchNotRecorded(error))
        }
        return .success(adoptedAt)
    }

    /// Records that QBank Cloud's bank is the one this phone uses, for a person who has no bank on this
    /// phone at all: a first launch on a second device. No bank file is made, so there is nothing to
    /// keep and nothing to offer.
    public static func adoptWithNoBankHere(record: BankHandoverRecord, at date: Date = Date()) throws(StoreError) {
        try record.save(BankHandover.onPhone.inCloud(since: date))
    }
}
