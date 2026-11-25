import Foundation
import UIKit

/// What Apple answers when the person agrees to Sign in with Apple.
nonisolated struct AppleCredential: Sendable, Equatable {
    /// Apple's id of the person: the same at every Sign in with Apple to this app.
    let user: String
    /// The identity token the server checks, as UTF-8 text.
    let identityToken: String
    /// The email Apple shares, the person's own or a private relay address, or nil when it shares
    /// none. Apple names it in the credential at the first sign-in only, so after that it is read from
    /// the identity token: for the phone to show and to fill in, never to trust. The server reads the
    /// token itself.
    let email: String?
    /// The authorization code Apple gave with this sign-in, as UTF-8 text, good once for five
    /// minutes. Deleting a store account sends it, for the server to revoke Apple's tokens with; a
    /// sign-in does not. Nil when Apple gave none.
    let authorizationCode: String?

    init(user: String, identityToken: String, email: String?, authorizationCode: String? = nil) {
        self.user = user
        self.identityToken = identityToken
        self.email = email ?? Self.email(inToken: identityToken)
        self.authorizationCode = authorizationCode
    }

    /// The `email` claim of an identity token, unchecked: a JWT's middle part is base64url JSON.
    static func email(inToken token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = claims["email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }
}

/// How a Sign in with Apple ended without Apple's yes.
nonisolated enum AppleSignInFailure: Error, Equatable {
    /// She closed Apple's sheet. Nothing is said.
    case canceled
    /// Apple did not finish it: no connection to Apple, no Apple Account on the device, or Apple
    /// refused.
    case failed
}

/// Who asks Apple: the system's Sign in with Apple (`SystemAppleSignIn`), or a scripted stand-in in a
/// Debug launch scenario, so a test never reaches Apple or uses a real Apple Account.
protocol AppleSignInProvider: AnyObject {
    /// Shows Apple's sheet over `window`, asking for the person's email, with `hashedNonce` for Apple
    /// to write into the identity token, and answers what Apple said.
    func signIn(hashedNonce: String, over window: UIWindow?) async throws(AppleSignInFailure) -> AppleCredential
}
