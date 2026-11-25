import Foundation
import QBankKit
import Synchronization

/// Where a free account's question bank lives on this phone: one bank per person, named by its key,
/// Apple's id of the person (`docs/on-phone-bank.md`).
///
/// A bank is the only copy of a free person's study, so nothing here deletes one: signing out leaves
/// it, and signing in again as the same person opens it again. It sits apart from `PhoneStorage`'s
/// `Accounts/` folder, which a sign-out erases.
nonisolated struct PhoneBanks: Sendable {
    /// The bank of `key`, made empty when there is none yet.
    let open: @Sendable (_ key: String) throws -> LocalBank

    /// `Application Support/QBankKit/Banks/<key>/`, kept in the device's backup.
    static func standard() -> PhoneBanks {
        PhoneBanks { key in LocalBank(store: try LocalStore.standard(key: key)) }
    }

    /// `<root>/Banks/<key>/`, for a Debug launch scenario's own folder.
    static func files(root: URL) -> PhoneBanks {
        PhoneBanks { key in LocalBank(store: try LocalStore.open(key: key, in: root)) }
    }

    /// Kept in memory for as long as this value lives, for tests. Opening a key again finds what it
    /// left, as a relaunch would.
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
}
