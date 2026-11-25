#if DEBUG
import Foundation
import QBankKit

/// Deleting a store account on the fake server, with the real route's order and words
/// (`DELETE /api/me` for an account with no password): the three fields of a fresh Sign in with
/// Apple, then the identity token, which must match the nonce, name this account's Apple identity and
/// be taken once, then the delete, which ends every session of the account. Revoking Apple's tokens
/// with the authorization code is the real server's business with Apple; the fake only requires the
/// code. Only `DebugScriptedAppleSignIn`'s tokens reach it, so it reads their claims and checks no
/// signature.
nonisolated extension FakeQBankServer {
    func deleteAppleAccount(_ account: Account, body: [String: Any]) -> Reply {
        guard let token = body["identityToken"] as? String, !token.isEmpty, let nonce = body["nonce"] as? String, (16...256).contains(nonce.count),
            let code = body["authorizationCode"] as? String, !code.isEmpty
        else { return failure(400, "invalid_request", "Sign in with Apple again to delete this account.") }
        let refused = failure(401, "invalid_apple_token", "Apple did not confirm it's you. Sign in with Apple again to delete your account.")
        let hashed = AppleSignInNonce(value: nonce).hashed
        guard let claims = Self.claims(of: token), claims["nonce"] == hashed, let user = claims["sub"], user == account.appleUser else {
            return refused
        }
        let deleted = state.withLock { state -> Bool in
            guard state.takenAppleNonces.insert(hashed).inserted else { return false }
            state.accounts.removeAll { $0.email == account.email }
            state.sessions = state.sessions.filter { $0.value != account.email }
            return true
        }
        return deleted ? (200, ["status": "deleted"]) : refused
    }
}
#endif
