import Foundation

/// The body of `POST /api/sign-in/apple`: Apple's identity token for one sign-in, and the nonce the
/// app made for it.
///
/// The app asks Apple with the nonce's SHA-256 (`AppleSignInNonce.hashed`), Apple writes that hash
/// into the token, and the server checks that the nonce sent here hashes to it, so a token taken from
/// elsewhere cannot be sent with a nonce of the sender's own. The server takes a token once.
public struct AppleSignInRequest: Codable, Sendable, Equatable {
    /// The credential's `identityToken`, as UTF-8 text.
    public let identityToken: String
    /// The nonce as the app made it, not its hash.
    public let nonce: String

    public init(identityToken: String, nonce: String) {
        self.identityToken = identityToken
        self.nonce = nonce
    }
}

/// The body of `POST /api/me/apple`: a Sign in with Apple the app has just done, as
/// `AppleSignInRequest` sends it, with the signed-in account's current password beside it.
public struct AppleLinkRequest: Codable, Sendable, Equatable {
    /// The credential's `identityToken`, as UTF-8 text.
    public let identityToken: String
    /// The nonce as the app made it, not its hash.
    public let nonce: String
    /// The account's current password, which the server checks before it reads the token.
    public let password: String

    public init(identityToken: String, nonce: String, password: String) {
        self.identityToken = identityToken
        self.nonce = nonce
        self.password = password
    }
}

/// A nonce for one Sign in with Apple: random, used once, and long enough that no one can guess it.
public struct AppleSignInNonce: Sendable, Equatable {
    /// What the server is sent: 64 lowercase hex digits, within the 16 to 256 characters it takes.
    public let value: String

    /// A new nonce from the system's secure random source.
    public init() {
        var generator = SystemRandomNumberGenerator()
        self.init(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The nonce these bytes spell in lowercase hex.
    init(bytes: [UInt8]) {
        value = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The nonce of a sign-in made earlier, as the app made it.
    public init(value: String) {
        self.value = value
    }

    /// What Apple is asked with: the SHA-256 of `value`'s UTF-8 bytes, in lowercase hex, as the server
    /// computes it.
    public var hashed: String { SHA256.hex(Array(value.utf8)) }
}
