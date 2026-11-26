#if DEBUG
import Foundation
import QBankKit

/// QBank Cloud on the fake server, with the real routes' rules and words: a store account's first read
/// issues the token it buys with, a purchase counts only for a Cloud plan bought with the account's own
/// token, an invited account has Cloud without buying it, and every refusal records nothing. Only
/// `DebugFakeStore`'s transactions reach it, so the fake reads the transaction's claims and checks no
/// signature.
nonisolated extension FakeQBankServer {
    /// A stand-in for a transaction the App Store signed: a JWS's three parts, whose middle part names
    /// the transaction, the plan, the token it was bought with and when its period ends, as Apple's
    /// does. It is not signed; only this fake reads it.
    static func storeTransaction(id: UInt64, product: String, token: UUID, expiresAt: Date) -> String {
        let claims: [String: Any] = [
            "transactionId": String(id), "originalTransactionId": "1", "bundleId": "com.dimitrygallego.qbank", "productId": product,
            "type": "Auto-Renewable Subscription", "environment": "Sandbox", "appAccountToken": token.uuidString.lowercased(),
            "expiresDate": Int((expiresAt.timeIntervalSince1970 * 1000).rounded()),
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data()
        let part = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fake-store-header.\(part).fake-store-signature"
    }

    /// `GET /api/me/cloud`: whether the account has Cloud, with the token a store account buys with,
    /// issued at its first read.
    func cloudStatus(of account: Account) -> Reply {
        let current = state.withLock { state -> Account? in
            guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else { return nil }
            if state.accounts[index].origin == "store", state.accounts[index].storeToken == nil {
                state.accounts[index].storeToken = UUID().uuidString.lowercased()
            }
            return state.accounts[index]
        }
        guard let current else { return failure(401, "unauthenticated", "Sign in to continue.") }
        return (200, current.cloudStatus)
    }

    /// `POST /api/me/cloud/transactions`: records the period a Cloud transaction pays for, and answers
    /// the account's Cloud.
    func recordCloudTransaction(_ signed: String, for account: Account) -> Reply {
        if account.origin == "invited" {
            return failure(409, "cloud_included", "This account has Cloud already, at no charge. Nothing was recorded.")
        }
        guard let claims = Self.transactionClaims(signed), let product = claims["productId"] as? String,
            let token = claims["appAccountToken"] as? String, let expires = claims["expiresDate"] as? Double
        else {
            return failure(400, "transaction_unverified", "This purchase could not be checked with the App Store. Nothing was recorded.")
        }
        guard CloudProducts.all.contains(product) else {
            return failure(400, "transaction_not_cloud", "This purchase is not a Cloud plan. Nothing was recorded.")
        }
        let recorded = state.withLock { state -> Account? in
            guard let index = state.accounts.firstIndex(where: { $0.id == account.id }),
                state.accounts[index].storeToken == token.lowercased()
            else { return nil }
            state.accounts[index].cloudUntil = Date(timeIntervalSince1970: expires / 1000)
            return state.accounts[index]
        }
        guard let recorded else {
            return failure(409, "transaction_other_account", "This App Store subscription belongs to another QBank account. Nothing was recorded.")
        }
        return (200, recorded.cloudStatus)
    }

    /// The claims of a stand-in transaction, or nil when it is not one.
    private static func transactionClaims(_ signed: String) -> [String: Any]? {
        let parts = signed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "fake-store-header" else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
#endif
