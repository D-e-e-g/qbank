import Observation
import QBankKit
import UIKit

/// One Sign in with Apple, from the first screen, or from Settings while QBank's server has not
/// confirmed an earlier one: a fresh nonce, Apple's sheet asked with its hash, then the server.
@Observable
final class AppleSignInModel {
    private(set) var isSigningIn = false
    /// Why the last Sign in with Apple did not sign in, or nil.
    private(set) var problem: String?
    /// Set when the person's account signs in with email and password instead: the email Apple
    /// shared, to put in that door, or empty when it shared none. Nil otherwise.
    private(set) var emailDoor: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// Asks Apple over `window`, then sends the server what Apple said. Closing Apple's sheet says
    /// nothing; a server that cannot answer still opens the bank on this phone.
    func signIn(over window: UIWindow?) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        problem = nil
        emailDoor = nil
        defer { isSigningIn = false }
        let nonce = AppleSignInNonce()
        let credential: AppleCredential
        do {
            credential = try await app.appleSignIn.signIn(hashedNonce: nonce.hashed, over: window)
        } catch {
            problem = error == .canceled ? nil : AppleSignInWording.appleDidNotFinish
            return
        }
        switch await app.signInWithApple(credential, nonce: nonce) {
        case .signedIn, .awaitingServer:
            break
        case .refused(let reason, let door):
            problem = reason
            emailDoor = door
        }
    }
}
