import Foundation

/// The signed-in person.
public struct Account: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case student
        case admin
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

    public init(id: String, email: String, name: String, role: Role, mustChangePassword: Bool, palette: Palette = .dusk) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.mustChangePassword = mustChangePassword
        self.palette = palette
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(Role.self, forKey: .role)
        mustChangePassword = try container.decode(Bool.self, forKey: .mustChangePassword)
        palette = try container.decodeIfPresent(String.self, forKey: .palette).flatMap(Palette.init(rawValue:)) ?? .dusk
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

/// The answer to a password sign-in or a password change: a fresh bearer token.
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
