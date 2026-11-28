#if DEBUG
import CryptoKit
import Foundation
import QBankKit

/// The combine on the fake server, `POST /api/me/bank/combine`, with the real route's rules: for a
/// store account with Cloud only, it stores a combined bank in place of the account's only while that
/// bank still has the stamp the combined one carries, and only when the combined one holds every row
/// of it; it answers the counts it then holds and the new stamp. Every refusal stores nothing. The
/// stamp, which `GET /api/me/cloud` and the download carry too, is a fingerprint of the bank's rows, so
/// any write to the bank changes it. A scenario can pause combining, and make the next combines arrive
/// just after another device wrote to the bank. Compiled only into Debug builds.
nonisolated extension FakeQBankServer {
    static let bankChanged = "Your bank in QBank Cloud changed while this one was being combined. Nothing was changed."
    static let notStoreAccount = "This account's bank is only on the server, so there is nothing to combine. Nothing was changed."
    static let rowsMissing = "This bank leaves out items your bank in QBank Cloud holds. Nothing was changed."

    /// `POST /api/me/bank/combine`: stores `archive`, combined on the phone, as the account's bank.
    func combineBank(_ archive: Data?, for account: Account) -> Reply {
        guard account.origin == "store" else { return failure(403, "not_store_account", Self.notStoreAccount) }
        guard account.cloudUntil.map({ $0 > .now }) == true else { return failure(403, "cloud_required", Self.cloudRequired) }
        let sent = archive.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["stamp"] as? String
        // Another device wrote to the bank just before this one arrived.
        let overtaken = state.withLock { state -> Bool in
            guard state.combinesToRefuse > 0, var held = state.cloudBanks[account.id] else { return false }
            state.combinesToRefuse -= 1
            held.revision += 1
            state.cloudBanks[account.id] = held
            return true
        }
        guard !overtaken, let sent, sent == bankStamp(of: account) else { return failure(409, "bank_changed", Self.bankChanged) }
        let store: LocalStore
        let counts: BankCounts
        do {
            store = try LocalStore.inMemory()
            counts = try BankArchive.read(archive ?? Data(), into: store)
        } catch {
            return (400, ["error": "invalid_archive", "message": Self.notABank, "problems": [String(describing: error)]])
        }
        if let held = state.withLock({ $0.cloudBanks[account.id] }), !Self.holdsEveryRow(of: held.store, in: store) {
            return failure(409, "bank_rows_missing", Self.rowsMissing)
        }
        let combined = FakeCloudBank(store: store)
        state.withLock { $0.cloudBanks[account.id] = combined }
        return (200, ["counts": counts.values, "stamp": combined.stamp() ?? ""])
    }

    /// The stamp of the account's bank on the server, or nil when it holds none: the fake's courses for
    /// an invited account, and an upload refused as `bank_not_empty` for a store account that holds one
    /// without rows here.
    func bankStamp(of account: Account) -> String? {
        if account.origin == "invited" { return "fake-invited-bank" }
        let (held, holds) = state.withLock { ($0.cloudBanks[account.id], $0.bankHolders.contains(account.id)) }
        guard let held else { return holds ? "fake-held-bank" : nil }
        return held.stamp()
    }

    /// The store account `applePerson`'s bank as its download sends it now, with its stamp.
    func applePersonsDownload() throws -> (archive: Data, stamp: String?) {
        guard let held = state.withLock({ $0.cloudBanks["fake-apple-person"] }) else { throw URLError(.fileDoesNotExist) }
        let stamp = held.stamp()
        return (try held.archive(stamp: stamp), stamp)
    }

    /// Pauses combining, as the server can with no app update.
    func pauseCombining() {
        state.withLock { $0.combinePaused = true }
    }

    /// Refuses the next `count` combines with `bank_changed`, each as if another device wrote to the
    /// bank just before it arrived.
    func refuseCombines(_ count: Int) {
        state.withLock { $0.combinesToRefuse = count }
    }

    /// Whether every row of `held` is in `combined`, by its id, or for a table whose rows have none, by
    /// how many there are.
    private static func holdsEveryRow(of held: LocalStore, in combined: LocalStore) -> Bool {
        guard let before = try? rows(of: held), let after = try? rows(of: combined) else { return false }
        for table in BankArchive.tableKeys {
            let old = before[table] ?? []
            let new = after[table] ?? []
            let ids = Set(new.compactMap(rowID))
            if old.contains(where: { rowID($0).map { !ids.contains($0) } ?? false }) || new.count < old.count { return false }
        }
        return true
    }

    private static func rows(of store: LocalStore) throws -> [String: [[String: Any]]] {
        let document = try JSONSerialization.jsonObject(with: BankArchive.write(from: store, at: .now)) as? [String: Any] ?? [:]
        return BankArchive.tableKeys.reduce(into: [:]) { rows, table in
            rows[table] = document[table] as? [[String: Any]] ?? (document[table] as? [String: Any]).map { [$0] } ?? []
        }
    }

    private static func rowID(_ row: [String: Any]) -> String? {
        row["id"] as? String ?? row["questionLineageId"] as? String
    }
}

/// A store account's bank on the fake server: a real `LocalBank` that answers its requests, over the
/// store it keeps, and how many times another device wrote to it, which its stamp carries.
nonisolated struct FakeCloudBank: Sendable {
    let store: LocalStore
    let bank: LocalBank
    var revision = 0

    init(store: LocalStore) {
        self.store = store
        bank = LocalBank(store: store)
    }

    /// A fingerprint of every row, as the server's stamp is one, or nil when the bank holds no row.
    func stamp() -> String? {
        guard let counts = try? BankArchive.counts(of: store), counts.values.values.contains(where: { $0 > 0 }),
            let archive = try? BankArchive.write(from: store, at: Date(timeIntervalSince1970: 0))
        else { return nil }
        // The stamp the bank was last read with is not part of what it holds.
        let rows = String(decoding: archive, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("  \"stamp\": ") }
        let digest = SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "fake-\(digest)-\(revision)"
    }

    /// The whole bank as the server sends it: written by the server, with `stamp`.
    func archive(stamp: String?) throws -> Data {
        try store.transaction { transaction in
            try transaction.execute("DELETE FROM bank_archive")
            if let stamp { try transaction.execute("INSERT INTO bank_archive (singleton, stamp) VALUES (1, ?)", [.text(stamp)]) }
        }
        let text = String(decoding: try BankArchive.write(from: store, at: .now), as: UTF8.self)
        return Data(text.replacingOccurrences(of: "  \"writtenBy\": \"phone\",\n", with: "  \"writtenBy\": \"server\",\n").utf8)
    }
}
#endif
