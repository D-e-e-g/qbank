#if DEBUG
import Foundation
import QBankKit

/// The fake server's accounts and sessions, with the rules and words of the real routes: sign-in,
/// sign-up from the owner's list, a new password, the color scheme, deleting the account, and
/// what the owner's read-only view of a user account is answered.
nonisolated extension FakeQBankServer {
    // MARK: The admin

    /// What only the admin's session is answered: the accounts it may look at, that it makes no
    /// questions, and the refusal of every write to the account it looks at, in the server's words.
    /// Its own account, Repair and the temporary password are its own; a file check writes nothing.
    func adminAnswer(method: String, path: String, body: [String: Any], email: String) -> Reply? {
        switch (method, path) {
        case ("GET", "/api/admin/students"):
            return (200, Self.adminStudents)
        case ("GET", "/api/question-maker"):
            guard let (status, answer) = questionMaker.answer(method: method, path: path, body: body, email: email, library: self) else { return nil }
            return (status, answer.merging(["available": false, "reason": Self.adminReadOnly]) { _, refused in refused })
        case ("POST", "/api/imports/check"), ("PUT", "/api/me/palette"):
            return nil
        case ("GET", _):
            return nil
        case ("POST", "/api/attempts"):
            return failure(403, "admin_cannot_record_answer", "The admin cannot record an answer as her.")
        case (_, _) where path.hasPrefix("/api/admin/"):
            return nil
        case (_, _) where path.hasPrefix("/api/exams/") && (method == "DELETE" || path.hasSuffix("/undo-delete")):
            return failure(403, "admin_cannot_delete_exam", "Only the user account can delete her exams or bring them back.")
        default:
            return failure(403, "admin_read_only", Self.adminReadOnly)
        }
    }

    private static let adminReadOnly = "This is a read-only view of a user account. Nothing here can be changed."

    private static var adminStudents: [String: Any] {
        [
            "students": [
                ["id": "fake-student", "email": viewedEmail, "name": "Sam Student", "createdAt": "2026-01-05T12:00:00.000Z"],
                ["id": "fake-maker", "email": maker.email, "name": "Max Maker", "createdAt": "2026-02-09T12:00:00.000Z"],
            ],
            "viewingId": "fake-student",
        ]
    }

    // MARK: Accounts

    func account(for token: String) -> Account? {
        state.withLock { state in
            state.sessions[token].flatMap { email in state.accounts.first { $0.email == email } }
        }
    }

    func signIn(email: String, password: String) -> Reply {
        let normalized = email.lowercased()
        return startSession { $0.email == normalized && $0.password == password }
    }

    /// A user account for the email on the sign-up list, signed in at once, as the real route makes
    /// it: the fields' rules first, then the lock, then the list. Any other email, or one that has
    /// an account, gets the same refusal, and the fifth refusal locks that email's sign-up.
    func signUp(email: String, password: String) -> Reply {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), (8...128).contains(password.utf16.count) else {
            return failure(400, "invalid_request", "Check the fields and try again.")
        }
        let made = state.withLock { state -> Bool? in
            if state.signUpRefusals[normalized, default: 0] >= Self.signUpLimit { return nil }
            guard normalized == Self.signUpEmail, !state.accounts.contains(where: { $0.email == normalized }) else {
                state.signUpRefusals[normalized, default: 0] += 1
                return state.signUpRefusals[normalized]! >= Self.signUpLimit ? nil : false
            }
            state.signUpRefusals[normalized] = nil
            let name = String(normalized.prefix { $0 != "@" })
            state.accounts.append(Account(id: "fake-new-user", email: normalized, name: name, password: password, mustChangePassword: false))
            return true
        }
        switch made {
        case nil:
            var reply = failure(429, "too_many_attempts", "Too many tries. Try again in 15 minutes.")
            reply.1["retryAfterSeconds"] = 900
            return reply
        case false?:
            return failure(403, "sign_up_refused", "This email can't sign up here. If you already have an account, sign in. Otherwise, ask the owner to add your email.")
        case true?:
            let (status, body) = startSession { $0.email == normalized }
            return (status == 200 ? 201 : status, body)
        }
    }

    private static let signUpLimit = 5
    /// Wrong passwords before deleting the account locks, as sign-in locks.
    private static let passwordLimit = 5

    /// A new session for the account that matches, as a sign-in answers it.
    private func startSession(for matches: (Account) -> Bool) -> Reply {
        let signedIn = state.withLock { state -> (String, Account)? in
            guard let account = state.accounts.first(where: matches) else { return nil }
            state.tokenCount += 1
            let token = state.tokenCount == 1 ? Self.sessionToken : "\(Self.sessionToken)-\(state.tokenCount)"
            state.sessions[token] = account.email
            return (token, account)
        }
        guard let (token, account) = signedIn else {
            return failure(401, "invalid_credentials", "That email or password is not right.")
        }
        return (200, ["token": token, "user": account.json, "expiresAt": date(days: 30)])
    }

    /// Deletes the account signed in, for good, in the real route's order: the fields' rules, a
    /// temporary password, the lock, her password, then a job still running in one of her courses.
    /// Its sessions end on every device, and it signs in no more. The fifth wrong password locks it.
    func deleteAccount(_ account: Account, password: String) -> Reply {
        guard (1...128).contains(password.utf16.count) else {
            return failure(400, "invalid_request", "Check the fields and try again.")
        }
        if account.mustChangePassword {
            return failure(403, "must_change_password", "Choose a new password to continue.")
        }
        let checked = state.withLock { state -> Bool? in
            if state.wrongDeletePasswords[account.email, default: 0] >= Self.passwordLimit { return nil }
            guard password == account.password else {
                state.wrongDeletePasswords[account.email, default: 0] += 1
                return state.wrongDeletePasswords[account.email]! >= Self.passwordLimit ? nil : false
            }
            return true
        }
        switch checked {
        case nil:
            var reply = failure(429, "too_many_attempts", "Too many tries. Try again in 15 minutes.")
            reply.1["retryAfterSeconds"] = 900
            return reply
        case false?:
            return failure(401, "invalid_credentials", "That password is not right.")
        case true?:
            break
        }
        if let inUse = accountInUse(email: account.email) {
            return failure(409, "in_use", inUse)
        }
        state.withLock { state in
            state.accounts.removeAll { $0.email == account.email }
            state.sessions = state.sessions.filter { $0.value != account.email }
        }
        return (200, ["status": "deleted"])
    }

    /// The sentence refusing to delete her account now: a job still running in one of her courses.
    private func accountInUse(email: String) -> String? {
        let courses = state.withLock { $0.courses.filter { $0.deletedAt == nil } }
        for course in courses {
            if twinJobs.isWorking(courseID: course.id, email: email) {
                return "QBank is still writing exam twins in \(Self.name(course)). Wait until they are filed, or cancel them, then delete your account."
            }
            if questionMaker.isRunning(courseID: course.id, email: email) {
                return "QBank is still making a set in \(Self.name(course)). Wait until it is filed, or cancel it, then delete your account."
            }
        }
        return nil
    }

    /// Her color scheme, which the real route takes only by its name and answers with her account.
    func setPalette(_ account: Account, to palette: String?) -> Reply {
        guard let palette, ["dusk", "slate"].contains(palette) else {
            return failure(400, "invalid_request", "Check the fields and try again.")
        }
        let updated = state.withLock { state -> Account in
            let index = state.accounts.firstIndex { $0.email == account.email }!
            state.accounts[index].palette = palette
            return state.accounts[index]
        }
        return (200, updated.json)
    }

    func changePassword(_ account: Account, token: String, current: String, new: String) -> Reply {
        // The real route's order: the fields' rules, then the same password, then the current one.
        guard !current.isEmpty, (8...128).contains(new.utf16.count) else {
            return failure(400, "invalid_request", "Check the fields and try again.")
        }
        guard new != current else {
            return failure(400, "same_password", "Choose a password that is different from the temporary one.")
        }
        guard current == account.password else {
            return failure(401, "invalid_credentials", "That password is not right.")
        }
        let (fresh, updated) = state.withLock { state -> (String, Account) in
            let index = state.accounts.firstIndex { $0.email == account.email }!
            state.accounts[index].password = new
            state.accounts[index].mustChangePassword = false
            state.tokenCount += 1
            let fresh = "\(Self.sessionToken)-\(state.tokenCount)"
            state.sessions = state.sessions.filter { $0.value != account.email }
            state.sessions[fresh] = account.email
            return (fresh, state.accounts[index])
        }
        return (200, ["token": fresh, "user": updated.json, "expiresAt": date(days: 30)])
    }
}
#endif
