import Foundation
import QBankKit
import Synchronization
@testable import QBank

extension PhoneBanks {
    /// Banks that open as `open` says, each with a record kept in memory for as long as this value
    /// lives, for a test that never deletes the account.
    init(open: @escaping @Sendable (_ key: String) throws -> LocalBank) {
        self.init(open: open, handover: PhoneBanks.memory().handover, erase: { _ in })
    }
}

/// What a delete did, in the order it did it, from every side it touches: Apple's sheet, the phone's
/// banks, the server and the keychain. A test reads one list to check the order of the steps.
final class DeletionLog: Sendable {
    private let entries = Mutex<[String]>([])

    var steps: [String] { entries.withLock { $0 } }

    func add(_ step: String) {
        entries.withLock { $0.append(step) }
    }

    /// How many times `step` happened.
    func count(_ step: String) -> Int {
        steps.filter { $0 == step }.count
    }
}

/// Banks in memory that write each open and erase into `log`. `failingErases` erases fail first,
/// as a full or locked disk would, and leave the bank as it was.
func loggedBanks(_ log: DeletionLog, failingErases: Int = 0) -> PhoneBanks {
    let memory = PhoneBanks.memory()
    let failures = Mutex(failingErases)
    return PhoneBanks(
        open: { key in
            log.add("open bank")
            return try memory.open(key)
        },
        handover: memory.handover,
        erase: { key in
            struct DiskRefused: Error {}
            let fails = failures.withLock { left in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            log.add(fails ? "erase bank failed" : "erase bank")
            if fails { throw DiskRefused() }
            try memory.erase(key)
        }
    )
}

/// A session store in memory that writes each clear into `log`: the keychain step of a delete.
final class LoggedSessionStore: SessionStore {
    private let inner: InMemorySessionStore
    private let log: DeletionLog

    init(_ session: StoredSession?, log: DeletionLog) {
        inner = InMemorySessionStore(session)
        self.log = log
    }

    func load() throws(StorageError) -> StoredSession? {
        try inner.load()
    }

    func save(_ session: StoredSession) throws(StorageError) {
        try inner.save(session)
    }

    func clear() throws(StorageError) {
        log.add("clear keychain")
        try inner.clear()
    }
}
