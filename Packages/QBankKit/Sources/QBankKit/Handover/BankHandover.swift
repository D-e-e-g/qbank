import Foundation
import Synchronization

/// Where a store account's bank is, as this phone records it beside the bank, and a move of it that
/// is under way: the hand-over of `docs/cloud.md`.
///
/// One side holds the bank at a time. `phone`: the bank on this phone answers every bank request.
/// `cloud`: the bank moved to QBank Cloud, the server's copy is the one in use, and the bank file on
/// this phone stays as it was, a safety copy that nothing writes to. The authority changes only at
/// the end of a move whose counts matched, table by table.
///
/// A move takes a lease before it reads the bank and gives it back when it ends, whichever way it
/// ends. While the lease is held the bank takes no writes. A lease found at launch is a move the app
/// was closed during; the app deals with it before anything else. A bank has no record until its
/// first move, so no record at all is a bank on this phone with no move under way.
public struct BankHandover: Codable, Sendable, Equatable {
    /// The side that holds the bank.
    public enum Authority: String, Codable, Sendable {
        case phone
        case cloud
    }

    /// A move under way.
    public struct Lease: Codable, Sendable, Equatable {
        /// Which way the bank is moving.
        public enum Direction: String, Codable, Sendable {
            /// The bank on this phone is being sent to QBank Cloud.
            case toCloud
        }

        public let direction: Direction
        public let startedAt: Date

        public init(direction: Direction, startedAt: Date) {
            self.direction = direction
            self.startedAt = startedAt
        }
    }

    /// The record's own format. A reader refuses any other, and leaves the file as it is.
    public static let currentVersion = 1

    public let version: Int
    public let authority: Authority
    /// The move under way, or nil.
    public let lease: Lease?
    /// When the bank last moved to QBank Cloud: from then on the bank file on this phone is a safety
    /// copy of the bank as it was that day.
    public let movedToCloudAt: Date?

    public init(authority: Authority, lease: Lease? = nil, movedToCloudAt: Date? = nil) {
        version = Self.currentVersion
        self.authority = authority
        self.lease = lease
        self.movedToCloudAt = movedToCloudAt
    }

    /// A bank on this phone with no move under way: what a bank with no record is.
    public static let onPhone = BankHandover(authority: .phone)

    /// The same record with `lease` in place of its own.
    public func leased(_ lease: Lease?) -> BankHandover {
        BankHandover(authority: authority, lease: lease, movedToCloudAt: movedToCloudAt)
    }
}

/// Where a bank's hand-over record is kept: `handover.json` beside the bank's file, in the bank's
/// own folder (`Banks/<key>/`), or in memory for tests.
///
/// It is read without opening the bank, so a bank whose authority is QBank Cloud is never opened,
/// and its file, the safety copy, is never touched. Each save writes the whole record or nothing, and
/// the file has the bank's protection and stays in the device's backup with it. A record that cannot
/// be read is never taken as either side: reading it throws, and the file is left as it is.
public final class BankHandoverRecord: Sendable {
    /// The record's file, or nil in memory.
    public let fileURL: URL?
    private let memory = Mutex<Data?>(nil)

    static let fileName = "handover.json"

    private init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// The record of the bank of `key`, beside it under `Application Support/QBankKit/Banks/<key>/`.
    public static func standard(key: String) throws(StoreError) -> BankHandoverRecord {
        let root: URL
        do {
            root = try FileLocations.applicationSupport()
        } catch {
            throw .storage(operation: error.operation, reason: error.reason)
        }
        return try file(key: key, in: root)
    }

    /// The record of the bank of `key`, beside it under `root/Banks/<key>/`.
    public static func file(key: String, in root: URL) throws(StoreError) -> BankHandoverRecord {
        BankHandoverRecord(fileURL: try StoreFiles.directory(forKey: key, in: root).appendingPathComponent(fileName))
    }

    /// A record in memory, with nothing in it yet, for tests.
    public static func inMemory() -> BankHandoverRecord {
        BankHandoverRecord(fileURL: nil)
    }

    /// What the record says: `BankHandover.onPhone` when there is none yet.
    public func load() throws(StoreError) -> BankHandover {
        let data: Data?
        if let fileURL {
            do {
                data = try FileLocations.read(fileURL, operation: "read the bank's hand-over record")
            } catch {
                throw .storage(operation: error.operation, reason: error.reason)
            }
        } else {
            data = memory.withLock { $0 }
        }
        guard let data else { return .onPhone }
        let handover: BankHandover
        do {
            handover = try QBankJSON.decoder.decode(BankHandover.self, from: data)
        } catch {
            throw .unreadableHandover(String(describing: error))
        }
        guard handover.version == BankHandover.currentVersion else {
            throw .unreadableHandover("version \(handover.version), and this app reads version \(BankHandover.currentVersion)")
        }
        return handover
    }

    /// Writes `handover` in place of the record, whole or not at all.
    public func save(_ handover: BankHandover) throws(StoreError) {
        let data: Data
        do {
            data = try QBankJSON.encoder.encode(handover)
        } catch {
            throw .storage(operation: "write the bank's hand-over record", reason: String(describing: error))
        }
        guard let fileURL else {
            memory.withLock { $0 = data }
            return
        }
        try StoreFiles.prepare(directory: fileURL.deletingLastPathComponent())
        do {
            try FileLocations.write(data, to: fileURL, operation: "write the bank's hand-over record")
        } catch {
            throw .storage(operation: error.operation, reason: error.reason)
        }
    }
}
