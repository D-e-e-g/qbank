import Foundation

/// Bank archive v1: one JSON document that holds a whole bank, as a row copy of the twelve tables
/// of the phone's store (`docs/on-phone-bank.md`, "Bank archive v1"). It is what moves between the
/// phone and Cloud in both directions, and it is the file Settings > Export shares.
///
/// `write` reads the whole bank in one consistent snapshot and `read` stores a document into an
/// empty bank, whole or not at all. Only Settings > Export my bank uses `write` so far, through
/// `LocalBank.exportArchive()` for a free account.
public enum BankArchive {
    /// The text that names the document.
    public static let format = "qbank-bank-archive"
    /// The version this build writes and reads. A reader refuses any other.
    public static let version = 1

    /// The twelve table keys, in the archive's order: each table after the ones it refers to.
    public static var tableKeys: [String] { BankArchiveTables.all.map(\.key) }

    /// The bank as a document. The rows are read in one snapshot, so the counts in it are the rows in it.
    public static func write(from store: LocalStore, at date: Date) throws -> Data {
        try BankArchiveWriter.write(from: store, at: date)
    }

    /// Stores `data` into `store`, which must hold no bank yet, in one transaction. Returns the counts
    /// of the rows now stored, which equal the document's own. When anything is wrong with the
    /// document, or the store already holds a row, it throws and the store is as it was.
    @discardableResult
    public static func read(_ data: Data, into store: LocalStore) throws -> BankCounts {
        try BankArchiveReader.read(data, into: store)
    }

    /// How many rows each table of the bank holds, deleted rows and old versions included. Compare
    /// it with the counts the other side answers after an upload.
    public static func counts(of store: LocalStore) throws -> BankCounts {
        try store.read { try BankArchiveWriter.counts(in: $0) }
    }
}

/// How many rows each of the twelve tables holds. `studyPlace` is 1 or 0.
public struct BankCounts: Sendable, Equatable, Codable, CustomStringConvertible {
    /// The count of each table, by the table's archive key.
    public let values: [String: Int]

    /// Counts for every table, or nil when a key is missing, one is not a table, or one is negative.
    public init?(_ values: [String: Int]) {
        guard Set(values.keys) == Set(BankArchive.tableKeys), values.values.allSatisfy({ $0 >= 0 }) else { return nil }
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let values = try [String: Int](from: decoder)
        guard let counts = BankCounts(values) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The counts are not the twelve tables' counts."))
        }
        self = counts
    }

    public func encode(to encoder: any Encoder) throws { try values.encode(to: encoder) }

    public subscript(_ table: String) -> Int? { values[table] }

    public var description: String { BankArchive.tableKeys.map { "\($0) \(values[$0] ?? -1)" }.joined(separator: ", ") }
}

/// Why a document was not stored, or could not be written. Nothing is stored in any of these cases.
public enum BankArchiveError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The text is not one JSON document: cut off, altered, or not JSON at all.
    case unreadable(String)
    /// It is JSON, but not a bank archive.
    case notAnArchive
    /// A version of the format this build does not implement.
    case unsupportedVersion(Int)
    /// The writer left rows out to keep the document closed, and a bank moves only whole.
    case incomplete
    /// A rule of the format is broken, as a sentence naming the table and the row.
    case invalid(String)
    /// A table's rows do not number what the counts say.
    case countsDiffer(table: String, declared: Int, found: Int)
    /// The store already holds part of a bank. A document is read into a fresh bank only.
    case bankNotEmpty
    /// The bank file refused the rows or failed.
    case storage(StoreError)

    public var description: String {
        switch self {
        case .unreadable(let reason): "This file is not a readable bank archive: \(reason)."
        case .notAnArchive: "This file is not a bank archive."
        case .unsupportedVersion(let version): "This bank archive is version \(version), which this app cannot read."
        case .incomplete: "This bank archive left rows out, and a bank moves only whole."
        case .invalid(let reason): "This bank archive breaks a rule of the format: \(reason)"
        case .countsDiffer(let table, let declared, let found): "This bank archive counts \(declared) \(table) and holds \(found)."
        case .bankNotEmpty: "This phone already holds a bank, and an archive is read into an empty one only."
        case .storage(let error): "The bank on this phone could not take the archive: \(error)."
        }
    }
}
