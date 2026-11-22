import Foundation
import QBankKit
import Synchronization

/// Where each account's saved courses and unsent answers live on this phone. Every account has
/// its own, so answers made by one are never sent as another.
nonisolated struct PhoneStorage: Sendable {
    /// One account's saved content and unsent answers.
    nonisolated struct Account: Sendable {
        let cache: any ContentCache
        let pending: any PendingAttemptStore
        /// Moves an unsent-answers file this version cannot read out of the way, keeping it, so
        /// new answers can be saved. False when nothing could be moved.
        var setAsideUnreadableAnswers: @Sendable () -> Bool = { false }
    }

    let open: @Sendable (_ accountID: String) -> Account
    let erase: @Sendable (_ accountID: String) -> Void

    /// `<root>/Accounts/<account id>/`: `pending-attempts.json`, kept in backups, and `Content/`,
    /// left out of them because the server has it all.
    static func files(root: URL) -> PhoneStorage {
        let folder: @Sendable (String) -> URL = { accountID in
            root.appendingPathComponent("Accounts", isDirectory: true)
                .appendingPathComponent(safeName(accountID), isDirectory: true)
        }
        return PhoneStorage(
            open: { accountID in
                let pending = folder(accountID).appendingPathComponent("pending-attempts.json")
                return Account(
                    cache: FileContentCache(directory: folder(accountID).appendingPathComponent("Content", isDirectory: true)),
                    pending: FilePendingAttemptStore(fileURL: pending),
                    setAsideUnreadableAnswers: {
                        let aside = pending.deletingLastPathComponent()
                            .appendingPathComponent("pending-attempts.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                        return (try? FileManager.default.moveItem(at: pending, to: aside)) != nil
                    }
                )
            },
            erase: { accountID in
                try? FileManager.default.removeItem(at: folder(accountID))
            }
        )
    }

    /// `Application Support/QBankKit/Accounts`, or memory when the phone cannot give a folder.
    static func standard() -> PhoneStorage {
        guard let root = try? FileLocations.applicationSupport() else { return memory() }
        return files(root: root)
    }

    /// Kept in memory for as long as this value lives, for tests and previews. Opening an account
    /// again finds what it left, as a relaunch would.
    static func memory() -> PhoneStorage {
        let accounts = Mutex<[String: Account]>([:])
        return PhoneStorage(
            open: { accountID in
                accounts.withLock { accounts in
                    if let account = accounts[accountID] { return account }
                    let account = Account(cache: InMemoryContentCache(), pending: InMemoryPendingAttemptStore())
                    accounts[accountID] = account
                    return account
                }
            },
            erase: { accountID in
                _ = accounts.withLock { $0.removeValue(forKey: accountID) }
            }
        )
    }

    /// Account ids come from the server; anything outside a safe folder name is replaced.
    private static func safeName(_ id: String) -> String {
        String(
            id.unicodeScalars.map { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_") ? Character(scalar) : "_"
            })
    }
}
