import Foundation
import Synchronization

/// What one combine of the bank on this phone with QBank's did, kept beside the bank (`docs/cloud.md`,
/// After a combine): which way it went, the stamp of QBank's bank it was built on, what was joined, and
/// the counts. The combine works all of it out for its checks; the receipt keeps it, so what a combine
/// did can be read again later.
public struct BankCombineReceipt: Codable, Sendable, Equatable {
    /// Which bank the combine became.
    public enum Direction: String, Codable, Sendable {
        /// Stored in QBank Cloud, which this phone then uses (`BankCombineUp`).
        case up
        /// Written to a fresh file on this phone, which this phone then uses (`BankHandBack` combining).
        case down
    }

    /// The receipt's own format.
    public static let currentVersion = 1

    public let version: Int
    public let direction: Direction
    public let combinedAt: Date
    /// The stamp of QBank's bank as downloaded, which the combine was built on.
    public let serverStamp: String
    /// What was joined, the names kept, and each bank as the person counts it.
    public let ledger: BankCombine.Ledger
    /// The rows of each table of the combined bank.
    public let counts: BankCounts

    public init(direction: Direction, combinedAt: Date, serverStamp: String, ledger: BankCombine.Ledger, counts: BankCounts) {
        version = Self.currentVersion
        self.direction = direction
        self.combinedAt = combinedAt
        self.serverStamp = serverStamp
        self.ledger = ledger
        self.counts = counts
    }
}

/// The receipts of a bank's combines, in its folder beside its hand-over record (`Banks/<key>/`), one
/// file for each, `combine-<UTC time>.json`, or in memory for tests. A receipt is written whole or not at
/// all, with the bank's protection, and never over another; it stays in the device's backup with the
/// bank, and only Delete account, which erases the bank's folder, takes it away.
public final class BankCombineReceipts: Sendable {
    /// The bank's folder, or nil in memory.
    public let folder: URL?
    private let memory = Mutex<[BankCombineReceipt]>([])

    /// The receipts of the bank whose hand-over record is `record`, in the same folder.
    public init(beside record: BankHandoverRecord) {
        folder = record.fileURL?.deletingLastPathComponent()
    }

    /// Keeps `receipt` beside the bank.
    public func save(_ receipt: BankCombineReceipt) throws(StoreError) {
        let data: Data
        do {
            data = try QBankJSON.encoder.encode(receipt)
        } catch {
            throw .storage(operation: "write a combine's receipt", reason: String(describing: error))
        }
        guard let folder else {
            memory.withLock { $0.append(receipt) }
            return
        }
        try StoreFiles.prepare(directory: folder)
        // A name already taken, as after the clock was set back, moves on by a millisecond.
        var date = receipt.combinedAt
        var file = folder.appendingPathComponent(Self.fileName(at: date))
        while FileManager.default.fileExists(atPath: file.path) {
            date = date.addingTimeInterval(0.001)
            file = folder.appendingPathComponent(Self.fileName(at: date))
        }
        do {
            try FileLocations.write(data, to: file, operation: "write a combine's receipt")
        } catch {
            throw .storage(operation: error.operation, reason: error.reason)
        }
    }

    /// Every receipt kept, oldest first.
    public func all() throws(StoreError) -> [BankCombineReceipt] {
        guard let folder else { return memory.withLock { $0 } }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw .storage(operation: "read the combines' receipts", reason: error.localizedDescription)
        }
        return try names.filter { $0.hasPrefix("combine-") && $0.hasSuffix(".json") }.sorted().map { name throws(StoreError) in
            do {
                return try QBankJSON.decoder.decode(BankCombineReceipt.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
            } catch {
                throw .storage(operation: "read a combine's receipt", reason: String(describing: error))
            }
        }
    }

    static func fileName(at date: Date) -> String {
        "combine-\(StoreFiles.dated(date)).json"
    }
}
