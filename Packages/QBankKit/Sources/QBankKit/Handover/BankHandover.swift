import Foundation
import Synchronization

/// Where a store account's bank is, as this phone records it beside the bank, and a move of it that
/// is under way: the hand-over of `docs/cloud.md`.
///
/// One side holds the bank at a time. `phone`: the bank on this phone answers every bank request.
/// `cloud`: QBank Cloud's copy is the one in use, and the bank file on this phone stays as it was, a
/// safety copy that nothing writes to. The authority changes only at the end of a move whose counts
/// matched, table by table (`BankMoveToCloud`, `BankHandBack`), or when this phone takes the bank
/// QBank Cloud already holds, which moves nothing (`BankAdoption`).
///
/// A move takes a lease before it reads or writes a bank and gives it back when it ends, whichever
/// way it ends. A lease found at launch is a move the app was closed during; the app deals with it
/// before anything else. A bank has no record until its first move, so no record at all is a bank on
/// this phone, in its first file, with no move under way.
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
            /// The bank on this phone is being sent to QBank Cloud. While it is, the bank takes no writes.
            case toCloud
            /// QBank Cloud's bank is coming back to this phone, into the fresh file `file`.
            case toPhone
        }

        public let direction: Direction
        public let startedAt: Date
        /// For a move to this phone: the fresh file it writes the bank into, which becomes the bank only
        /// once the switch is recorded. A lease found at launch names the file to take away.
        public let file: String?

        public init(direction: Direction, startedAt: Date, file: String? = nil) {
            self.direction = direction
            self.startedAt = startedAt
            self.file = file
        }
    }

    /// The record's own format, which every save writes. Version 2 added `bankFile`: an app that
    /// reads only version 1 refuses the record and opens no bank, rather than open a file that is not
    /// the bank in use.
    public static let currentVersion = 2
    /// The versions this app reads. A record of version 1 names no file: its bank is the first file.
    /// A reader refuses any other version, and leaves the file as it is.
    public static let readableVersions = 1...currentVersion

    public let version: Int
    public let authority: Authority
    /// The move under way, or nil.
    public let lease: Lease?
    /// When the bank last went to QBank Cloud, by a move or because this phone took the bank QBank
    /// Cloud already held: from then on the bank file on this phone is a safety copy of the bank as it
    /// was that day.
    public let movedToCloudAt: Date?
    /// The file in the bank's folder that is this phone's own bank: the bank in use while the authority
    /// is the phone's, and the safety copy while it is QBank Cloud's. `LocalStore.firstFile` until the
    /// bank first comes back from QBank Cloud, into a fresh file.
    public let bankFile: String
    /// When the bank last came back to this phone from QBank Cloud.
    public let returnedAt: Date?
    /// The sets of this phone's bank, by id, that QBank Cloud did not hold when this phone took QBank
    /// Cloud's bank: offered to add to it as new sets, until they are added.
    public let offeredSets: [String]

    public init(
        authority: Authority, lease: Lease? = nil, movedToCloudAt: Date? = nil, bankFile: String = LocalStore.firstFile, returnedAt: Date? = nil,
        offeredSets: [String] = []
    ) {
        version = Self.currentVersion
        self.authority = authority
        self.lease = lease
        self.movedToCloudAt = movedToCloudAt
        self.bankFile = bankFile
        self.returnedAt = returnedAt
        self.offeredSets = offeredSets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        authority = try container.decode(Authority.self, forKey: .authority)
        lease = try container.decodeIfPresent(Lease.self, forKey: .lease)
        movedToCloudAt = try container.decodeIfPresent(Date.self, forKey: .movedToCloudAt)
        bankFile = try container.decodeIfPresent(String.self, forKey: .bankFile) ?? LocalStore.firstFile
        returnedAt = try container.decodeIfPresent(Date.self, forKey: .returnedAt)
        offeredSets = try container.decodeIfPresent([String].self, forKey: .offeredSets) ?? []
    }

    /// A bank on this phone with no move under way: what a bank with no record is.
    public static let onPhone = BankHandover(authority: .phone)

    /// The same record with `lease` in place of its own.
    public func leased(_ lease: Lease?) -> BankHandover {
        BankHandover(
            authority: authority, lease: lease, movedToCloudAt: movedToCloudAt, bankFile: bankFile, returnedAt: returnedAt, offeredSets: offeredSets)
    }

    /// The record once the bank is QBank Cloud's, since `date`, with no lease: this phone's bank file
    /// is the safety copy from then on, and `offering` its sets that QBank Cloud does not hold.
    public func inCloud(since date: Date, offering: [String] = []) -> BankHandover {
        BankHandover(authority: .cloud, movedToCloudAt: date, bankFile: bankFile, returnedAt: returnedAt, offeredSets: offering)
    }

    /// The record once the bank came back from QBank Cloud into `file`, at `date`, with no lease: the
    /// bank on this phone is in that file from then on.
    public func onPhone(in file: String, since date: Date) -> BankHandover {
        BankHandover(authority: .phone, movedToCloudAt: movedToCloudAt, bankFile: file, returnedAt: date)
    }

    /// The same record, offering only `sets`.
    public func offering(_ sets: [String]) -> BankHandover {
        BankHandover(authority: authority, lease: lease, movedToCloudAt: movedToCloudAt, bankFile: bankFile, returnedAt: returnedAt, offeredSets: sets)
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
        guard BankHandover.readableVersions.contains(handover.version) else {
            throw .unreadableHandover("version \(handover.version), and this app reads versions up to \(BankHandover.currentVersion)")
        }
        // A record names a file only in the bank's own folder.
        for file in [handover.bankFile] + [handover.lease?.file].compactMap(\.self) {
            guard (try? StoreFiles.validate(fileName: file)) != nil else { throw .unreadableHandover("it names \(file), which is not a bank file") }
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
