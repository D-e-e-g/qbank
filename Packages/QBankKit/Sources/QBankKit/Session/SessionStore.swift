import Foundation
import Synchronization

/// What the device keeps after sign-in.
///
/// A Sign in with Apple that Apple confirmed while QBank's server could not be reached is kept too,
/// so the bank on the phone opens without the server: it has no bearer token yet, and `unsent` holds
/// what to send the server again. A session kept by a version from before Sign in with Apple reads
/// with neither, as the password sign-in it was.
public struct StoredSession: Codable, Sendable, Equatable {
    /// The bearer token from sign-in, sent as `Authorization: Bearer`. Empty while the server has not
    /// answered a Sign in with Apple (`awaitsServer`).
    public let token: String
    public let expiresAt: Date?
    /// The account as of the last sign-in or session check, so the app can open offline. While the
    /// server has not answered a Sign in with Apple, the account as Apple described it.
    public let account: Account?
    /// Apple's id of the person, for a session Sign in with Apple made: the same at every Sign in
    /// with Apple to this app, and known before the server answers, so it names the person's bank on
    /// this phone. Nil for a password sign-in.
    public let appleUser: String?
    /// The Sign in with Apple to send the server again, while it has not answered one. Nil once the
    /// server answered, and once a try showed the same one cannot be sent again.
    public let unsent: AppleSignInRequest?

    public init(token: String, expiresAt: Date? = nil, account: Account? = nil, appleUser: String? = nil, unsent: AppleSignInRequest? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.account = account
        self.appleUser = appleUser
        self.unsent = unsent
    }

    /// Apple confirmed a sign-in on this phone and QBank's server has not: there is no session on the
    /// server yet, so nothing may be asked of it with this one.
    public var awaitsServer: Bool { token.isEmpty }
}

/// Where the session lives between launches.
public protocol SessionStore: Sendable {
    func load() throws(StorageError) -> StoredSession?
    func save(_ session: StoredSession) throws(StorageError)
    func clear() throws(StorageError)
}

/// A session store in memory, for tests and previews.
public final class InMemorySessionStore: SessionStore {
    private let session: Mutex<StoredSession?>

    public init(_ session: StoredSession? = nil) {
        self.session = Mutex(session)
    }

    public func load() throws(StorageError) -> StoredSession? {
        session.withLock { $0 }
    }

    public func save(_ session: StoredSession) throws(StorageError) {
        self.session.withLock { $0 = session }
    }

    public func clear() throws(StorageError) {
        session.withLock { $0 = nil }
    }
}
