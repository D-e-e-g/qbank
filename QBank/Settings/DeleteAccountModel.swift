import Foundation
import Observation
import QBankKit

/// Settings' Delete account: her current password, sent to `DELETE /api/me`, which deletes the
/// user account signed in and everything in it, for good. The server ends its sessions on every
/// device, and the phone forgets it as a sign-out does. A refusal deletes nothing and keeps her
/// signed in, in the server's words.
@Observable
final class DeleteAccountModel {
    var password = ""
    private(set) var isDeleting = false
    private(set) var problem: String?
    /// Until when the server refuses another try after too many wrong passwords. Delete waits for it.
    private(set) var lockedUntil: Date?

    static let noPassword = "Enter your password to delete your account."

    private let app: AppModel
    private let now: () -> Date

    init(app: AppModel, now: @escaping () -> Date = Date.init) {
        self.app = app
        self.now = now
    }

    /// Settings offers it to an invited user account, which is deleted with its password; the
    /// admin's cannot be deleted. A store account is deleted with a fresh Sign in with Apple instead.
    static func isOffered(to account: Account?, kind: AccountKind = .invited) -> Bool {
        kind.deletesWithPassword && account?.role == .student
    }

    var canDelete: Bool {
        !isDeleting && lockedUntil == nil
    }

    /// Answers still on the phone that QBank does not have, which go with the account.
    var waitingCount: Int {
        app.offline?.waiting.count ?? 0
    }

    func delete() async {
        guard canDelete else { return }
        guard !password.isEmpty else {
            problem = Self.noPassword
            return
        }
        isDeleting = true
        problem = nil
        defer { isDeleting = false }
        do {
            try await app.deleteAccount(password: password)
        } catch {
            report(error)
        }
    }

    /// Lets her try again once the lock's time has passed, and drops the line that said how long.
    func lockEnded() {
        guard let lockedUntil, now() >= lockedUntil else { return }
        self.lockedUntil = nil
        problem = nil
    }

    private func report(_ error: QBankError) {
        // An ended session signs her out; a temporary password leads to choosing a new one.
        if app.handle(error) { return }
        problem = Wording.problem(error)
        switch error.serverCode {
        case .invalidCredentials:
            password = ""
        case .tooManyAttempts:
            password = ""
            if case .server(let server) = error, let seconds = server.retryAfterSeconds {
                lockedUntil = now().addingTimeInterval(TimeInterval(seconds))
            }
        default:
            break
        }
    }
}
