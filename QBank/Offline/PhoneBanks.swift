import Foundation
import QBankKit
import Synchronization

/// Where a store account's question bank lives on this phone: one bank per person, named by its key,
/// Apple's id of the person (`docs/on-phone-bank.md`), with the bank's hand-over record beside it,
/// which says whether the bank is still this phone's or moved to QBank Cloud, and in which of its files
/// it is (`docs/cloud.md`).
///
/// A bank is the only copy of a free person's study, so only deleting the account erases one:
/// signing out leaves it, and signing in again as the same person opens it again. Once the bank moved
/// to QBank Cloud, its file stays here as it was, a safety copy, until the account is deleted. A bank
/// that came back from QBank Cloud is in a fresh file beside the ones before it, which stay as they
/// were; short of deleting the account, the only file ever taken away is a fresh one a hand-back made
/// and never used. It all sits apart from `PhoneStorage`'s `Accounts/` folder, which a sign-out erases.
nonisolated struct PhoneBanks: Sendable {
    private let openFile: @Sendable (_ key: String, _ file: String) throws -> LocalBank
    private let createFile: @Sendable (_ key: String, _ file: String) throws -> LocalStore
    private let removeFile: @Sendable (_ key: String, _ file: String) -> Void
    private let readFile: @Sendable (_ key: String, _ file: String) throws -> LocalStore
    private let hasBank: @Sendable (_ key: String) -> Bool
    /// The hand-over record of the bank of `key`. Reading it never opens the bank.
    let handover: @Sendable (_ key: String) throws -> BankHandoverRecord
    /// Erases the bank of `key` and everything kept beside it, every bank file and its hand-over record
    /// too, for the person's own delete of their account and nothing else. A bank that is not there is
    /// already erased. Close it first.
    let erase: @Sendable (_ key: String) throws -> Void

    init(
        open: @escaping @Sendable (_ key: String, _ file: String) throws -> LocalBank,
        create: @escaping @Sendable (_ key: String, _ file: String) throws -> LocalStore,
        removeUnused: @escaping @Sendable (_ key: String, _ file: String) -> Void,
        readOnly: @escaping @Sendable (_ key: String, _ file: String) throws -> LocalStore,
        exists: @escaping @Sendable (_ key: String) -> Bool,
        handover: @escaping @Sendable (_ key: String) throws -> BankHandoverRecord,
        erase: @escaping @Sendable (_ key: String) throws -> Void
    ) {
        openFile = open
        createFile = create
        removeFile = removeUnused
        readFile = readOnly
        hasBank = exists
        self.handover = handover
        self.erase = erase
    }

    /// The bank of `key` in its file `file`. The first file is made empty when there is none yet; a
    /// later file, which a hand-back wrote, does not open when it is missing.
    func open(_ key: String, file: String = LocalStore.firstFile) throws -> LocalBank {
        try openFile(key, file)
    }
    /// A new, empty bank file `file` of `key`, beside the bank's other files. A name already taken is
    /// refused with `StoreError.fileExists`, never written over.
    func create(_ key: String, file: String) throws -> LocalStore {
        try createFile(key, file)
    }

    /// Takes away `file` of `key`, a fresh file a hand-back made and never used. The bank's first file
    /// is never taken away.
    func removeUnused(_ key: String, file: String) {
        removeFile(key, file)
    }

    /// The bank file `file` of `key`, opened only to read, such as the safety copy of a bank in QBank
    /// Cloud: nothing is written to it, not even a schema step.
    func readOnly(_ key: String, file: String) throws -> LocalStore {
        try readFile(key, file)
    }

    /// Whether `key` has ever had a bank or a hand-over record on this phone. Nothing is made to find out.
    func exists(_ key: String) -> Bool {
        hasBank(key)
    }

    /// `Application Support/QBankKit/Banks/<key>/`, kept in the device's backup.
    static func standard() -> PhoneBanks {
        PhoneBanks(
            open: { key, file in LocalBank(store: try LocalStore.standard(key: key, file: file)) },
            create: { key, file in try LocalStore.createStandard(key: key, file: file) },
            removeUnused: { key, file in try? LocalStore.removeUnusedStandard(key: key, file: file) },
            readOnly: { key, file in try LocalStore.readOnlyStandard(key: key, file: file) },
            exists: { key in (try? LocalStore.existsStandard(key: key)) ?? true },
            handover: { key in try BankHandoverRecord.standard(key: key) },
            erase: { key in try LocalStore.erase(key: key) })
    }

    /// `<root>/Banks/<key>/`, for a Debug launch scenario's own folder.
    static func files(root: URL) -> PhoneBanks {
        PhoneBanks(
            open: { key, file in LocalBank(store: try LocalStore.open(key: key, in: root, file: file)) },
            create: { key, file in try LocalStore.create(key: key, in: root, file: file) },
            removeUnused: { key, file in try? LocalStore.removeUnused(key: key, in: root, file: file) },
            readOnly: { key, file in try LocalStore.readOnly(key: key, in: root, file: file) },
            exists: { key in (try? LocalStore.exists(key: key, in: root)) ?? true },
            handover: { key in try BankHandoverRecord.file(key: key, in: root) },
            erase: { key in try LocalStore.erase(key: key, in: root) })
    }

    /// Kept in memory for as long as this value lives, for tests. Opening a file again finds what it
    /// left, as a relaunch would, and so does a record, until the key is erased. A file opened to read
    /// is the same store.
    static func memory() -> PhoneBanks {
        /// Each file's store, and the bank opened over it once it is opened, by key and file name.
        let files = Mutex<[String: (store: LocalStore, bank: LocalBank?)]>([:])
        let records = Mutex<[String: BankHandoverRecord]>([:])
        let record: @Sendable (String) -> BankHandoverRecord = { key in
            records.withLock { records in
                if let record = records[key] { return record }
                let record = BankHandoverRecord.inMemory()
                records[key] = record
                return record
            }
        }
        let name: @Sendable (String, String) -> String = { key, file in "\(key)/\(file)" }
        return PhoneBanks(
            open: { key, file in
                try files.withLock { files in
                    let found = files[name(key, file)]
                    if let bank = found?.bank { return bank }
                    guard found != nil || file == LocalStore.firstFile else {
                        throw StoreError.storage(operation: "open the bank", reason: "\(file) is not in the bank's folder")
                    }
                    let store = try found?.store ?? LocalStore.inMemory()
                    let bank = LocalBank(store: store)
                    files[name(key, file)] = (store, bank)
                    return bank
                }
            },
            create: { key, file in
                try files.withLock { files in
                    guard files[name(key, file)] == nil else { throw StoreError.fileExists(file) }
                    let store = try LocalStore.inMemory()
                    files[name(key, file)] = (store, nil)
                    return store
                }
            },
            removeUnused: { key, file in
                guard file != LocalStore.firstFile else { return }
                _ = files.withLock { $0.removeValue(forKey: name(key, file)) }
            },
            readOnly: { key, file in
                guard let store = files.withLock({ $0[name(key, file)]?.store }) else {
                    throw StoreError.storage(operation: "open the bank to read it", reason: "\(file) is not in the bank's folder")
                }
                return store
            },
            exists: { key in
                files.withLock { $0.keys.contains { $0.hasPrefix("\(key)/") } } || (try? record(key).load()).map { $0 != .onPhone } == true
            },
            handover: record,
            erase: { key in
                let erased = files.withLock { files in
                    let keys = files.keys.filter { $0.hasPrefix("\(key)/") }
                    return keys.compactMap { files.removeValue(forKey: $0)?.bank }
                }
                erased.forEach { $0.close() }
                records.withLock { _ = $0.removeValue(forKey: key) }
            })
    }
}
