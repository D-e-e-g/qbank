import QBankKit

/// What the phone says about a Sign in with Apple that did not end signed in, and which answers mean
/// QBank's server could not answer it, so the bank on the phone opens without it.
///
/// Every refusal `POST /api/sign-in/apple` documents has its own plain sentence. None closes the door
/// to email and password: the first screen always offers it, and a person waiting for the server can
/// sign out to reach it.
enum AppleSignInWording {
    /// Apple's sheet ended without a yes, for a reason other than her closing it.
    static let appleDidNotFinish = "Sign in with Apple did not finish. Try again."

    /// The bank on the phone could not be opened, so she is not signed in.
    static var bankDidNotOpen: String {
        "QBank could not open the questions kept on this \(Device.model). Try again."
    }

    /// Said in Settings while QBank's server has not confirmed a Sign in with Apple.
    static var awaitsServer: String {
        "QBank's server has not confirmed your sign-in yet. Your questions are on this \(Device.model) and work without it, and QBank tries again on its own."
    }

    /// Said in Settings while QBank's server has not confirmed a Sign in with Apple and refused the one
    /// kept to send again, so QBank does not try again on its own.
    static var needsAppleSignInAgain: String {
        "This \(Device.model) is not connected to the QBank service yet. Your questions stay on this \(Device.model). Sign in with Apple again to connect it, or sign out and use an existing QBank account."
    }

    /// Said under Color while QBank's server has not confirmed a Sign in with Apple.
    static let paletteAwaitsServer = "Your color is saved to your account once QBank's server confirms your sign-in."

    /// Said under Color once QBank's server refused the kept Sign in with Apple, so only a new one
    /// lets the color be saved.
    static let paletteNeedsAppleSignInAgain = "Sign in with Apple again to save your color to your account."

    /// Whether QBank's server could not answer the sign-in, now or at all: no answer reached the
    /// phone, the server failed (5xx), or its answer could not be read. Apple said yes, so the bank on
    /// the phone opens all the same and the sign-in is sent again later. Anything else is a refusal.
    static func serverCannotAnswer(_ error: QBankError) -> Bool {
        switch error {
        case .transport, .cancelled, .unexpectedResponse:
            true
        case .server(let server):
            server.status >= 500
        case .notSignedIn, .storage, .invalidRequest:
            false
        }
    }

    /// The plain words for what the server answered, or for why it could not.
    static func problem(_ error: QBankError) -> String {
        switch error.serverCode?.rawValue {
        case "invalid_apple_token":
            return "Apple did not confirm this sign-in. Try Sign in with Apple again."
        case "password_account":
            return "This email already has a QBank account with a password. Sign in with your email and password instead."
        case "email_in_use":
            return "This email already belongs to another QBank account. Sign in to that account with its email and password, or use another Apple Account."
        case "too_many_attempts":
            if case .server(let server) = error, let seconds = server.retryAfterSeconds {
                let minutes = max(1, (seconds + 59) / 60)
                return "Too many tries from this network. Try again in \(Wording.count(minutes, "minute")), or use an existing QBank account."
            }
            return "Too many tries from this network. Try again later, or use an existing QBank account."
        case "invalid_request":
            return appleDidNotFinish
        case "apple_unreachable", "auth_failed":
            return "QBank could not check this sign-in with Apple. Try again in a moment."
        case "apple_sign_in_unavailable":
            return "Sign in with Apple is not available on QBank's server yet. Try again later, or use an existing QBank account."
        case "auth_unavailable":
            return "QBank's server cannot sign anyone in right now. Try again later."
        default:
            return Wording.problem(error) ?? "Something went wrong. Try again."
        }
    }
}
