import Foundation

/// How an account stands with Cloud, which QBank's server decides: the answer to `GET /api/me/cloud`
/// and to `POST /api/me/cloud/transactions` (`docs/cloud.md`).
///
/// The app never grants Cloud from what the App Store says. It buys with `storeToken`, sends the server
/// the transaction Apple signed, and shows Cloud as on only when the server answers `active`.
public struct CloudStatus: Codable, Sendable, Equatable {
    /// What `GET /api/me/cloud` says of the account's bank on the server, which an account without
    /// Cloud may read too: whether there is one, and whether combining is paused (S-16).
    public struct Bank: Sendable, Equatable {
        /// The stamp of the account's bank, the one its download carries: a fingerprint compared only
        /// for equality. Nil when the server holds no bank for the account.
        public let stamp: String?
        /// While true, the phone starts no combine of its bank with the server's, in either direction.
        public let combinePaused: Bool

        public init(stamp: String?, combinePaused: Bool) {
            self.stamp = stamp
            self.combinePaused = combinePaused
        }
    }

    /// Whether the account has Cloud now. An invited account always has it.
    public let active: Bool
    /// When the latest subscription that was not revoked ends, or ended. Nil for an account that never
    /// had one, and for an invited account.
    public let expiresAt: Date?
    /// The token a store account buys Cloud with: the purchase carries it as its `appAccountToken`, so
    /// the transaction Apple signs names this account. The server issues it at the account's first read
    /// and keeps it. Nil for an invited account, which has Cloud without buying it.
    public let storeToken: UUID?
    /// The account's bank on the server, as `GET /api/me/cloud` says it. Nil in an answer that does not
    /// say, as the answer to a transaction.
    public let bank: Bank?

    /// Every field the kit reads: those of the contract's `CloudBankStatus`, each always sent by
    /// `GET /api/me/cloud`, null when there is none. Listed so a test can hold the kit to the contract.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case active, expiresAt, storeToken, bankStamp, combinePaused
    }

    public init(active: Bool, expiresAt: Date?, storeToken: UUID?, bank: Bank? = nil) {
        self.active = active
        self.expiresAt = expiresAt
        self.storeToken = storeToken
        self.bank = bank
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decode(Bool.self, forKey: .active)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        storeToken = try container.decodeIfPresent(UUID.self, forKey: .storeToken)
        // Only the answer that reads the account's Cloud says anything of its bank.
        if container.contains(.combinePaused) {
            bank = Bank(
                stamp: try container.decodeIfPresent(String.self, forKey: .bankStamp),
                combinePaused: try container.decode(Bool.self, forKey: .combinePaused))
        } else {
            bank = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(active, forKey: .active)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(storeToken, forKey: .storeToken)
        if let bank {
            try container.encode(bank.stamp, forKey: .bankStamp)
            try container.encode(bank.combinePaused, forKey: .combinePaused)
        }
    }
}

/// The two Cloud plans, by the product ids App Store Connect and the server know them by. The server
/// takes a purchase of no other product as Cloud.
public enum CloudProducts {
    public static let monthly = "com.dimitrygallego.qbank.cloud.monthly"
    public static let yearly = "com.dimitrygallego.qbank.cloud.yearly"

    /// Both plans, in the order the plans sheet shows them.
    public static let all = [monthly, yearly]
}

/// The body of `POST /api/me/cloud/transactions`.
struct CloudTransactionUpload: Codable, Sendable {
    /// The transaction as the App Store signed it: StoreKit's `jwsRepresentation`, a compact JWS.
    let signedTransaction: String
}
