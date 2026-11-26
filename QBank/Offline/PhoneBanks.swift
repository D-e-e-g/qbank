import Foundation
import QBankKit
import Synchronization

/// Where a store account's question bank lives on this phone: one bank per person, named by its key,
/// Apple's id of the person (`docs/on-phone-bank.md`), with the bank's hand-over record beside it,
/// which says whether the bank is still this phone's or moved to QBank Cloud (`docs/cloud.md`).
///
/// A bank is the only copy of a free person's study, so nothing here deletes one: signing out leaves
/// it, and signing in again as the same person opens it again. Once the bank moved to QBank Cloud, its
/// file stays here as it was, a safety copy. It sits apart from `PhoneStorage`'s `Accounts/` folder,
/// which a sign-out erases.
nonisolated struct PhoneBanks: Sendable {
    /// The bank of `key`, made empty when there is none yet.
    let open: @Sendable (_ key: String) throws -> LocalBank
    /// The hand-over record of the bank of `key`. Reading it never opens the bank.
    let handover: @Sendable (_ key: String) throws -> BankHandoverRecord

    init(open: @escaping @Sendable (_ key: String) throws -> LocalBank, handover: @escaping @Sendable (_ key: String) throws -> BankHandoverRecord) {
        self.open = open
        self.handover = handover
    }

    /// Banks that `open` gives, each with a record kept in memory for as long as this value lives.
    init(open: @escaping @Sendable (_ key: String) throws -> LocalBank) {
        self.init(open: open, handover: Self.memoryRecords())
    }

    /// `Application Support/QBankKit/Banks/<key>/`, kept in the device's backup.
    static func standard() -> PhoneBanks {
        PhoneBanks(
            open: { key in LocalBank(store: try LocalStore.standard(key: key)) },
            handover: { key in try BankHandoverRecord.standard(key: key) })
    }

    /// `<root>/Banks/<key>/`, for a Debug launch scenario's own folder.
    static func files(root: URL) -> PhoneBanks {
        PhoneBanks(
            open: { key in LocalBank(store: try LocalStore.open(key: key, in: root)) },
            handover: { key in try BankHandoverRecord.file(key: key, in: root) })
    }

    /// Kept in memory for as long as this value lives, for tests. Opening a key again finds what it
    /// left, as a relaunch would, and so does its record.
    static func memory() -> PhoneBanks {
        let banks = Mutex<[String: LocalBank]>([:])
        return PhoneBanks { key in
            try banks.withLock { banks in
                if let bank = banks[key] { return bank }
                let bank = LocalBank(store: try LocalStore.inMemory())
                banks[key] = bank
                return bank
            }
        }
    }

    /// A record in memory for each key, the same one each time the key is asked for.
    private static func memoryRecords() -> @Sendable (String) throws -> BankHandoverRecord {
        let records = Mutex<[String: BankHandoverRecord]>([:])
        return { key in
            records.withLock { records in
                if let record = records[key] { return record }
                let record = BankHandoverRecord.inMemory()
                records[key] = record
                return record
            }
        }
    }
}
