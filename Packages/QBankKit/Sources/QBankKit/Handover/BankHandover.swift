import Foundation
import Synchronization

/// Where a store account's bank is, as this phone records it beside the bank, and a move of it that
/// is under way: the hand-over of `docs/cloud.md`.
///
/// One side holds the bank at a time. `phone`: the bank on this phone answers every bank request.
/// `cloud`: QBank Cloud's copy is the one in use, and the bank file on this phone stays as it was, a
/// safety copy that nothing writes to. The authority changes only at the end of a move whose counts
/// matched, table by table (`BankMoveToCloud`, `BankHandBack`), or of a combine whose checks held
/// (`BankCombineUp`, and `BankHandBack` combining), or when a second device with no bank of its own
/// takes the bank QBank Cloud holds, which moves nothing.
///
/// A move or a combine takes a lease before it reads or writes a bank and gives it back when it ends,
/// whichever way it ends. A lease found at launch is one the app was closed during; the app deals with
/// it before anything else. A bank has no record until its first move, so no record at all is a bank
/// on this phone, in its first file, with no move under way.
public struct BankHandover: Codable, Sendable, Equatable {
    /// The side that holds the bank.
    public enum Authority: String, Codable, Sendable {
        case phone
        case cloud
    }

    /// A move or a combine under way.
    public struct Lease: Codable, Sendable, Equatable {
        /// Which way the bank is moving.
        public enum Direction: String, Codable, Sendable {
            /// The bank on this phone is being sent to QBank Cloud, whole or combined with the bank
            /// QBank Cloud holds. While it is, the bank takes no writes.
            case toCloud
            /// QBank's bank is coming to this phone, into the fresh file `file`: whole once Cloud has
            /// ended, or combined with the bank on this phone.
            case toPhone
        }

        public let direction: Direction
        public let startedAt: Date
        /// For a move to this phone: the fresh file it writes the bank into, which becomes the bank only
        /// once the switch is recorded. A lease found at launch names the file to take away.
        public let file: String?
        /// True for a combine of the bank on this phone with QBank's (`docs/cloud.md`, Combining two
        /// banks), which runs again when the app was closed during it.
        public let combines: Bool

        public init(direction: Direction, startedAt: Date, file: String? = nil, combines: Bool = false) {
            self.direction = direction
            self.startedAt = startedAt
            self.file = file
            self.combines = combines
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            direction = try container.decode(Direction.self, forKey: .direction)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            file = try container.decodeIfPresent(String.self, forKey: .file)
            combines = try container.decodeIfPresent(Bool.self, forKey: .combines) ?? false
        }

        /// A move's lease is written as it was before combines, which add only their mark.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(direction, forKey: .direction)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encodeIfPresent(file, forKey: .file)
            if combines { try container.encode(true, forKey: .combines) }
        }

        private enum CodingKeys: String, CodingKey {
            case direction, startedAt, file, combines
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
    /// When the bank last went to QBank Cloud, by a move, a combine, or a second device taking the bank
    /// QBank Cloud held: from then on the bank file on this phone is a safety copy of the bank as it was
    /// that day.
    public let movedToCloudAt: Date?
    /// The file in the bank's folder that is this phone's own bank: the bank in use while the authority
    /// is the phone's, and the safety copy while it is QBank Cloud's. `LocalStore.firstFile` until the
    /// bank first comes to this phone from QBank, into a fresh file.
    public let bankFile: String
    /// When a bank last came to this phone from QBank, whole or combined.
    public let returnedAt: Date?
    /// The stamp of QBank's bank this phone last took in, which a hand-back and a combine down write
    /// with their switch. A bank on the server under any other stamp is one this phone has not taken in.
    public let bankStamp: String?

    public init(
        authority: Authority, lease: Lease? = nil, movedToCloudAt: Date? = nil, bankFile: String = LocalStore.firstFile, returnedAt: Date? = nil,
        bankStamp: String? = nil
    ) {
        version = Self.currentVersion
        self.authority = authority
        self.lease = lease
        self.movedToCloudAt = movedToCloudAt
        self.bankFile = bankFile
        self.returnedAt = returnedAt
        self.bankStamp = bankStamp
    }

    /// A record of an earlier build that offered sets reads as one without them: those sets stay in
    /// the file that held them, untouched.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        authority = try container.decode(Authority.self, forKey: .authority)
        lease = try container.decodeIfPresent(Lease.self, forKey: .lease)
        movedToCloudAt = try container.decodeIfPresent(Date.self, forKey: .movedToCloudAt)
        bankFile = try container.decodeIfPresent(String.self, forKey: .bankFile) ?? LocalStore.firstFile
        returnedAt = try container.decodeIfPresent(Date.self, forKey: .returnedAt)
        bankStamp = try container.decodeIfPresent(String.self, forKey: .bankStamp)
    }

    /// A bank on this phone with no move under way: what a bank with no record is.
    public static let onPhone = BankHandover(authority: .phone)

    /// The same record with `lease` in place of its own.
    public func leased(_ lease: Lease?) -> BankHandover {
        BankHandover(authority: authority, lease: lease, movedToCloudAt: movedToCloudAt, bankFile: bankFile, returnedAt: returnedAt, bankStamp: bankStamp)
    }

    /// The record once the bank is QBank Cloud's, since `date`, with no lease: this phone's bank file
    /// is the safety copy from then on.
    public func inCloud(since date: Date) -> BankHandover {
        BankHandover(authority: .cloud, movedToCloudAt: date, bankFile: bankFile, returnedAt: returnedAt, bankStamp: bankStamp)
    }

    /// The record once QBank's bank, under `stamp`, came to this phone into `file`, at `date`, whole or
    /// combined with the bank that was here, with no lease: the bank on this phone is in that file
    /// from then on, and the file before it stays as it was.
    public func onPhone(in file: String, since date: Date, stamp: String?) -> BankHandover {
        BankHandover(authority: .phone, movedToCloudAt: movedToCloudAt, bankFile: file, returnedAt: date, bankStamp: stamp)
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
