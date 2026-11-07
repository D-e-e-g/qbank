import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything a QBankKit call can fail with.
public enum QBankError: Error, Sendable, Equatable {
    /// No session is stored on this device. Nothing was sent.
    case notSignedIn
    /// The request never got an answer: no signal, a timeout, DNS, TLS, or a dropped connection.
    case transport(URLError.Code)
    /// The task was cancelled before an answer came.
    case cancelled
    /// The server answered with an error the API documents: `{ "error": code, "message": text }`.
    case server(ServerError)
    /// The server answered with something the API does not document, such as a proxy's HTML page
    /// or a body that does not match the model. `status` is the HTTP status.
    case unexpectedResponse(status: Int, detail: String)
    /// The device could not read or write its own storage (Keychain or files).
    case storage(StorageError)
    /// The request could not be built. Nothing was sent.
    case invalidRequest(String)

    /// True when the request may succeed later without anything changing on the device:
    /// no connection, a server or proxy failure, or a rate limit.
    public var isTemporary: Bool {
        switch self {
        case .transport, .cancelled:
            return true
        case .server(let error):
            return error.status >= 500 || error.status == 429
        case .unexpectedResponse(let status, _):
            return status >= 500 || status == 429
        case .notSignedIn, .storage, .invalidRequest:
            return false
        }
    }

    /// True when the stored session is missing or the server no longer accepts it.
    public var needsSignIn: Bool {
        switch self {
        case .notSignedIn:
            return true
        case .server(let error):
            return error.status == 401 && error.code == .unauthenticated
        default:
            return false
        }
    }

    /// True when the server refused a write because an admin's session sent it: the admin only looks
    /// at the user account it has chosen, and nothing there can be changed.
    public var isAdminReadOnly: Bool {
        guard let code = serverCode else { return false }
        return code == .adminReadOnly || code == .adminCannotRecordAnswer || code == .adminCannotDeleteExam
    }

    /// The server code, when the server sent one.
    public var serverCode: ServerError.Code? {
        if case .server(let error) = self { return error.code }
        return nil
    }
}

/// An error body from the server.
public struct ServerError: Error, Sendable, Equatable {
    public let status: Int
    public let code: Code
    /// A sentence written for her. Screens can show it as is.
    public let message: String
    /// How long sign-in stays locked, from the body or the Retry-After header.
    public let retryAfterSeconds: Int?

    public init(status: Int, code: Code, message: String, retryAfterSeconds: Int? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// The machine-readable `error` field. Open, so a code the server adds later still decodes.
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }

        // Sign-in and session.
        public static let unauthenticated: Code = "unauthenticated"
        public static let invalidCredentials: Code = "invalid_credentials"
        /// Sign-up for an email not on the owner's list, or one that already has an account.
        public static let signUpRefused: Code = "sign_up_refused"
        public static let tooManyAttempts: Code = "too_many_attempts"
        public static let mustChangePassword: Code = "must_change_password"
        public static let samePassword: Code = "same_password"
        public static let authFailed: Code = "auth_failed"
        public static let authUnavailable: Code = "auth_unavailable"
        /// A call only her own signed-in session may make, such as deleting her account, sent with an agent key.
        public static let agentKeyNotAllowed: Code = "agent_key_not_allowed"
        /// Deleting the account, refused for the admin.
        public static let adminCannotDeleteAccount: Code = "admin_cannot_delete_account"
        // Connect an agent: no agent waiting under that code (mistyped, answered already, or run
        // out), and no key of hers with that id.
        public static let pairingNotFound: Code = "pairing_not_found"
        public static let agentKeyNotFound: Code = "agent_key_not_found"
        /// Any write to a user account's content from an admin's session.
        public static let adminReadOnly: Code = "admin_read_only"
        // Any request whose fields do not meet the route's rules, such as a new password under 8 characters.
        public static let invalidRequest: Code = "invalid_request"
        // Content.
        public static let requestRefused: Code = "request_refused"
        // Import: a file the importer refuses. The message is its first error.
        public static let invalidImport: Code = "invalid_import"
        // Making questions: an account the server does not allow, a server without its Claude key,
        // past the daily limit, and a set not at the step a call needs.
        public static let notAllowed: Code = "not_allowed"
        public static let notSetUp: Code = "not_set_up"
        public static let dailyLimit: Code = "daily_limit"
        public static let wrongStep: Code = "wrong_step"
        // Answers.
        public static let invalidResponse: Code = "invalid_response"
        public static let attemptConflict: Code = "attempt_conflict"
        public static let adminCannotRecordAnswer: Code = "admin_cannot_record_answer"
        public static let examOnly: Code = "exam_only"
        public static let questionNotFound: Code = "question_not_found"
        // Review.
        public static let confirmationRequired: Code = "confirmation_required"
        // Exams.
        public static let noWeeks: Code = "no_weeks"
        public static let weekNotFound: Code = "week_not_found"
        public static let noWrongQuestions: Code = "no_wrong_questions"
        public static let examNotFound: Code = "exam_not_found"
        public static let examFinished: Code = "exam_finished"
        public static let alreadyAnswered: Code = "already_answered"
        public static let questionNotInExam: Code = "question_not_in_exam"
        public static let courseNotFound: Code = "course_not_found"
        // Deleting and Undo: what goes changed since the preview, a job or a running exam still
        // uses it, the exam is still going, Undo after 30 days, and the admin with her exams.
        public static let deletionChanged: Code = "deletion_changed"
        public static let inUse: Code = "in_use"
        public static let examInProgress: Code = "exam_in_progress"
        public static let undoExpired: Code = "undo_expired"
        public static let notDeleted: Code = "not_deleted"
        public static let adminCannotDeleteExam: Code = "admin_cannot_delete_exam"
    }
}

/// A failure of the device's own storage.
public struct StorageError: Error, Sendable, Equatable, CustomStringConvertible {
    /// What was being done, such as "save session" or "read pending answers".
    public let operation: String
    public let reason: String
    /// The Keychain status, when the Keychain failed.
    public let status: Int32?

    public init(operation: String, reason: String, status: Int32? = nil) {
        self.operation = operation
        self.reason = reason
        self.status = status
    }

    public var description: String {
        status.map { "\(operation) failed: \(reason) (\($0))" } ?? "\(operation) failed: \(reason)"
    }
}
