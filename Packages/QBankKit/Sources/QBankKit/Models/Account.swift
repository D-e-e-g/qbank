import Foundation

/// The signed-in person.
public struct Account: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case student
        case admin
    }

    /// How the account came to be, which decides where its bank lives (`AccountKind`).
    public enum Origin: String, Codable, Sendable {
        /// Set up by the owner, with an email and password, before the store release or since.
        case invited
        /// Made by Sign in with Apple in the iPhone app.
        case store
    }

    /// A way into the account (`signInWith`).
    public enum SignInMethod: String, Codable, Sendable {
        /// Its email and password.
        case password
        /// One or more passkeys, which the web app uses.
        case passkey
        /// Sign in with Apple: it made a store account, or an account with a password linked it.
        case apple
    }

    /// The account's color scheme, which follows it to every device. Look (light or dark) stays
    /// per device.
    public enum Palette: String, Codable, Sendable, CaseIterable {
        /// Mauve with peach, every account's until it picks another.
        case dusk
        /// Graphite.
        case slate
    }

    public let id: String
    public let email: String
    public let name: String
    public let role: Role
    /// True after the admin set a temporary password: most calls answer 403 `must_change_password`
    /// until she chooses a new one with `QBankClient.changePassword`.
    public let mustChangePassword: Bool
    /// Set with `QBankClient.setPalette`. A server from before color schemes, a session kept from
    /// then, or a scheme this version does not know reads as `.dusk`, as the server asks.
    public let palette: Palette
    /// A server from before store accounts, a session kept on the phone from then, or an origin this
    /// version does not know reads as `.invited`: every account that existed then was one, and an
    /// invited account's bank stays on the server, as it always has.
    public let origin: Origin
    /// The ways into the account now, as the server last said, each once. An invited account has
    /// `password`, and `apple` once it linked Sign in with Apple (`QBankClient.linkApple`); a store
    /// account has `apple`. A way this version does not know is left out, as the server asks. A server
    /// from before ways in, or a session kept on the phone from then, says none: an invited account
    /// reads as `password` alone and a store account as `apple` alone, which is all either could have
    /// on the phone then.
    public let signInWith: [SignInMethod]
    /// Whether the account has Cloud, as the server said with the session or the sign-in. Nil from a
    /// server from before Cloud, or a session kept on the phone from then: nothing is known.
    public let cloud: Cloud?

    /// Whether an account has Cloud, which the server decides (`docs/cloud.md`).
    public struct Cloud: Codable, Sendable, Equatable {
        /// Whether the account has Cloud now. An invited account always has it.
        public let active: Bool
        /// When the latest subscription that was not revoked ends, or ended.
        public let expiresAt: Date?

        public init(active: Bool, expiresAt: Date?) {
            self.active = active
            self.expiresAt = expiresAt
        }
    }

    public init(
        id: String, email: String, name: String, role: Role, mustChangePassword: Bool, palette: Palette = .dusk, origin: Origin = .invited,
        signInWith: [SignInMethod]? = nil, cloud: Cloud? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.mustChangePassword = mustChangePassword
        self.palette = palette
        self.origin = origin
        self.signInWith = signInWith ?? Self.waysIn(of: origin)
        self.cloud = cloud
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(Role.self, forKey: .role)
        mustChangePassword = try container.decode(Bool.self, forKey: .mustChangePassword)
        palette = try container.decodeIfPresent(String.self, forKey: .palette).flatMap(Palette.init(rawValue:)) ?? .dusk
        origin = try container.decodeIfPresent(String.self, forKey: .origin).flatMap(Origin.init(rawValue:)) ?? .invited
        signInWith = try container.decodeIfPresent([String].self, forKey: .signInWith)?.compactMap(SignInMethod.init(rawValue:)) ?? Self.waysIn(of: origin)
        // Added with Cloud. A value this version cannot read is taken as nothing known, never as off.
        cloud = try? container.decodeIfPresent(Cloud.self, forKey: .cloud)
    }

    /// Whether the account signs in with its email and password, so it can link Sign in with Apple.
    public var hasPassword: Bool { signInWith.contains(.password) }

    /// Whether Sign in with Apple lands in this account.
    public var signsInWithApple: Bool { signInWith.contains(.apple) }

    /// The ways in of an account whose server or kept session says none.
    private static func waysIn(of origin: Origin) -> [SignInMethod] {
        switch origin {
        case .invited: [.password]
        case .store: [.apple]
        }
    }
}

/// `GET /api/admin/students`: the user accounts the admin may look at, oldest first.
public struct StudentList: Codable, Sendable, Equatable {
    public struct Student: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let email: String
        public let name: String
    }

    public let students: [Student]
    /// The one the admin is looking at. Nil when there is no user account yet.
    public let viewingId: String?

    /// The one the admin is looking at, by its id.
    public var viewing: Student? {
        students.first { $0.id == viewingId }
    }
}

/// The answer to a sign-in, with a password or with Apple, or to a password change: a fresh bearer
/// token.
public struct SignedIn: Codable, Sendable, Equatable {
    public let token: String
    public let user: Account
    public let expiresAt: Date
}

/// `GET /api/session`.
public struct Session: Codable, Sendable, Equatable {
    public let user: Account
    public let expiresAt: Date
}

/// The body of `PUT /api/me/palette`.
struct PaletteUpdate: Codable {
    let palette: Account.Palette
}

/// `GET /health`.
public struct Health: Codable, Sendable, Equatable {
    public let status: String
    /// The commit the server runs.
    public let version: String
}
