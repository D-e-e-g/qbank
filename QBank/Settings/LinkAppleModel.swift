import Foundation
import Observation
import QBankKit
import UIKit

/// Settings' Sign in with Apple for an account with a password: her current password, then Apple's
/// sheet with a fresh nonce, then `POST /api/me/apple`, which links that Apple identity to her account
/// so Sign in with Apple opens it on a new phone, with no password. Linking changes nothing else: her
/// bank stays on the server, her email and password keep working, and she stays signed in. A refusal
/// links nothing and keeps her signed in, in plain words that say what to do next.
@Observable
final class LinkAppleModel {
    var password = ""
    private(set) var isLinking = false
    private(set) var problem: String?
    /// Until when the server refuses another try after too many wrong passwords or refused tokens.
    /// Linking waits for it.
    private(set) var lockedUntil: Date?

    private let app: AppModel
    private let now: () -> Date

    init(app: AppModel, now: @escaping () -> Date = Date.init) {
        self.app = app
        self.now = now
    }

    /// Settings offers it to an account that signs in with its email and password, which only an
    /// invited account does. A store account already signs in with Apple and has no password.
    static func isOffered(to account: Account?, kind: AccountKind) -> Bool {
        kind.hasPassword && account?.hasPassword == true
    }

    /// Whether Sign in with Apple already opens her account, from this phone or another.
    var isLinked: Bool {
        app.account?.signsInWithApple == true
    }

    var canLink: Bool {
        !isLinking && lockedUntil == nil && !isLinked
    }

    /// Asks Apple over `window` and links what Apple said. Closing Apple's sheet says nothing.
    func link(over window: UIWindow?) async {
        guard canLink else { return }
        guard !password.isEmpty else {
            problem = LinkAppleWording.noPassword
            return
        }
        isLinking = true
        problem = nil
        defer { isLinking = false }
        let nonce = AppleSignInNonce()
        let credential: AppleCredential
        do {
            credential = try await app.appleSignIn.signIn(hashedNonce: nonce.hashed, over: window)
        } catch {
            problem = error == .canceled ? nil : AppleSignInWording.appleDidNotFinish
            return
        }
        do {
            try await app.linkApple(credential, nonce: nonce, password: password)
            password = ""
        } catch {
            await report(error)
        }
    }

    /// Lets her try again once the lock's time has passed, and drops the line that said how long.
    func lockEnded() {
        guard let lockedUntil, now() >= lockedUntil else { return }
        self.lockedUntil = nil
        problem = nil
    }

    private func report(_ error: QBankError) async {
        // An ended session signs her out; a temporary password leads to choosing a new one.
        if app.handle(error) { return }
        problem = LinkAppleWording.problem(error)
        switch error.serverCode?.rawValue {
        case "invalid_credentials":
            password = ""
        case "too_many_attempts":
            password = ""
            if case .server(let server) = error, let seconds = server.retryAfterSeconds {
                lockedUntil = now().addingTimeInterval(TimeInterval(seconds))
            }
        case "apple_already_linked":
            // Her account has an Apple identity this phone did not know of: learn it, so Settings
            // shows it.
            await app.refreshSession()
        default:
            break
        }
    }
}

/// What Settings says when linking Sign in with Apple did not link. Every refusal `POST /api/me/apple`
/// documents has its own plain sentence, and each says what to do next: nothing was linked, she stays
/// signed in, and her email and password keep working. An ended session and a temporary password are
/// not said here: the app signs her out, or asks for a new password, as everywhere.
enum LinkAppleWording {
    static let noPassword = "Enter your current password to link Sign in with Apple."

    static func problem(_ error: QBankError) -> String {
        switch error.serverCode?.rawValue {
        case "invalid_credentials":
            return "That password is not right, so nothing was linked. Try again."
        case "invalid_apple_token":
            return "Apple did not confirm this sign-in, so nothing was linked. Try again."
        case "invalid_request":
            return AppleSignInWording.appleDidNotFinish
        case "apple_linked_elsewhere":
            return "This Apple Account already signs in to another QBank account, so it cannot be linked to this one. Nothing was linked. Try a different Apple Account, or keep signing in with your email and password."
        case "apple_already_linked":
            return "Your QBank account is already linked to a different Apple Account. Use that Apple Account to sign in with Apple, or keep signing in with your email and password."
        case "too_many_attempts":
            if case .server(let server) = error, let seconds = server.retryAfterSeconds {
                let minutes = max(1, (seconds + 59) / 60)
                return "Too many tries. Nothing was linked. Try again in \(Wording.count(minutes, "minute"))."
            }
            return "Too many tries. Nothing was linked. Try again later."
        case "apple_unreachable":
            return "QBank could not check this sign-in with Apple, so nothing was linked. Try again in a moment."
        case "apple_sign_in_unavailable":
            return "Sign in with Apple is not available on QBank's server yet, so nothing was linked. Try again later. Your email and password keep working."
        case "auth_unavailable":
            return "QBank's server cannot link Sign in with Apple right now. Try again later. Your email and password keep working."
        case "agent_key_not_allowed":
            return "QBank did not accept this request, so nothing was linked. Try again."
        default:
            return Wording.problem(error) ?? "Sign in with Apple was not linked. Try again."
        }
    }
}
