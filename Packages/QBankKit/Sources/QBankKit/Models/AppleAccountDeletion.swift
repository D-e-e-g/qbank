/// The body of `DELETE /api/me` for an account with no password, a store account: what Apple
/// answered a fresh Sign in with Apple, asked for just before the delete.
///
/// The server checks the identity token as Sign in with Apple does, and also that it names the
/// account's own Apple identity and was issued in the last five minutes. It then exchanges the
/// authorization code with Apple to revoke Apple's tokens, and deletes the account. A token and a
/// code are each good once, so every try of a delete asks Apple again.
public struct AppleAccountDeletionRequest: Codable, Sendable, Equatable {
    /// The credential's `identityToken`, as UTF-8 text.
    public let identityToken: String
    /// The nonce as the app made it, not its hash.
    public let nonce: String
    /// The credential's `authorizationCode`, as UTF-8 text.
    public let authorizationCode: String

    public init(identityToken: String, nonce: String, authorizationCode: String) {
        self.identityToken = identityToken
        self.nonce = nonce
        self.authorizationCode = authorizationCode
    }
}

/// How far deleting a store account has come on this phone, kept with the session
/// (`StoredSession.deletion`) so that a delete that stopped part way is finished, and no step that
/// is done runs again.
///
/// The phone's copy of the bank is erased before the account on the server, and the session is
/// forgotten last. A delete that stopped after the erase leaves the phone with nothing to open, so
/// the app offers only to finish it.
public enum AccountDeletionStep: String, Codable, Sendable {
    /// The person confirmed with Apple, and the phone's copy is being erased. A try that finds this
    /// erases again: erasing what is already gone changes nothing.
    case erasingPhone
    /// The phone's copy is erased, and the account on the server is next. A try that finds this goes
    /// straight to the server.
    case phoneErased
}
