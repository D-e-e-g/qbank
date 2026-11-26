import Foundation

/// How an account stands with Cloud, which QBank's server decides: the answer to `GET /api/me/cloud`
/// and to `POST /api/me/cloud/transactions` (`docs/cloud.md`).
///
/// The app never grants Cloud from what the App Store says. It buys with `storeToken`, sends the server
/// the transaction Apple signed, and shows Cloud as on only when the server answers `active`.
public struct CloudStatus: Codable, Sendable, Equatable {
    /// Whether the account has Cloud now. An invited account always has it.
    public let active: Bool
    /// When the latest subscription that was not revoked ends, or ended. Nil for an account that never
    /// had one, and for an invited account.
    public let expiresAt: Date?
    /// The token a store account buys Cloud with: the purchase carries it as its `appAccountToken`, so
    /// the transaction Apple signs names this account. The server issues it at the account's first read
    /// and keeps it. Nil for an invited account, which has Cloud without buying it.
    public let storeToken: UUID?

    /// Every field, each always sent, null when there is none. Listed so a test can hold the kit to the
    /// contract's `CloudStatus`.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case active, expiresAt, storeToken
    }

    public init(active: Bool, expiresAt: Date?, storeToken: UUID?) {
        self.active = active
        self.expiresAt = expiresAt
        self.storeToken = storeToken
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
