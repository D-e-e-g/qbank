#if DEBUG
import Foundation
import QBankKit

/// Sign in with Apple on the fake server, with the real route's rules and words: the token's nonce
/// must be the SHA-256 of the nonce sent, a token is taken once, an Apple identity is found by Apple's
/// id of the person and never by email, a new one gets a store account, and an email that already
/// belongs to an account is refused and never joined to it. Only `DebugScriptedAppleSignIn`'s tokens
/// reach it, so the fake reads the token's claims and checks no signature.
nonisolated extension FakeQBankServer {
    /// A stand-in for Apple's identity token: a JWT's three parts, whose middle part names Apple's id
    /// of the person, the email Apple shares and the hash of the nonce the app asked with. It is not
    /// signed; only this fake reads it.
    static func appleToken(user: String, email: String, hashedNonce: String) -> String {
        let claims = ["iss": "https://appleid.apple.com", "sub": user, "email": email, "nonce": hashedNonce]
        let payload = (try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data()
        let part = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fake-apple-header.\(part).fake-apple-signature"
    }

    /// `POST /api/sign-in/apple`: 200 for an Apple identity that has an account, 201 for a new one.
    func signInWithApple(identityToken: String, nonce: String) -> Reply {
        guard !identityToken.isEmpty, (16...256).contains(nonce.count) else {
            return failure(400, "invalid_request", "Check the fields and try again.")
        }
        let refused = failure(401, "invalid_apple_token", "Apple did not confirm this sign-in. Try again.")
        let hashed = AppleSignInNonce(value: nonce).hashed
        guard let email = AppleCredential.email(inToken: identityToken)?.lowercased(), let claims = Self.claims(of: identityToken),
            let user = claims["sub"], claims["nonce"] == hashed
        else { return refused }
        enum Found {
            case used, signedIn, made, passwordAccount, emailInUse
        }
        let found = state.withLock { state -> Found in
            guard state.takenAppleNonces.insert(hashed).inserted else { return .used }
            if state.accounts.contains(where: { $0.appleUser == user }) { return .signedIn }
            if let holder = state.accounts.first(where: { $0.email == email }) {
                return holder.password == nil ? .emailInUse : .passwordAccount
            }
            let name = String(email.prefix { $0 != "@" })
            state.accounts.append(Account(id: "fake-store-\(state.accounts.count)", email: email, name: name, password: nil, mustChangePassword: false, appleUser: user))
            return .made
        }
        switch found {
        case .used:
            return refused
        case .passwordAccount:
            return failure(409, "password_account", "This email already has a QBank account with a password. Sign in with your email and password instead.")
        case .emailInUse:
            return failure(409, "email_in_use", "This email already belongs to another QBank account.")
        case .signedIn, .made:
            let (status, body) = startSession { $0.appleUser == user }
            return (found == .made && status == 200 ? 201 : status, body)
        }
    }

    /// The text claims of a stand-in token, or nil when it is not one.
    private static func claims(of token: String) -> [String: String]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}
#endif
