#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// An in-process stand-in for the QBank server, for UI tests and simulator review. It answers the
/// app's calls with invented accounts, courses and questions, the way the real routes answer them,
/// and scores answers with the server's rules, so the app runs end to end through `QBankClient`
/// without a network or a real account.
nonisolated final class FakeQBankServer: HTTPTransport {
    struct Credentials {
        let email: String
        let password: String
    }

    /// A student who signs in normally and lands on the course she used last.
    static let student = Credentials(email: "student@example.com", password: "synthetic-pass-1")
    /// A student whose password the owner reset: she must choose a new one.
    static let resetStudent = Credentials(email: "reset@example.com", password: "synthetic-temp-1")
    /// The one student the server lets make questions, with a set being written and copies to check.
    static let maker = Credentials(email: "maker@example.com", password: "synthetic-pass-2")
    /// The owner, an admin, who looks at `student`'s account in the frozen view and changes nothing.
    static let owner = Credentials(email: "owner@example.com", password: "synthetic-pass-3")
    /// The email the owner's frozen view names for `student`'s account.
    static let viewedEmail = "sam@example.com"
    /// The one email on the owner's sign-up list, with no account yet: it signs up with any password
    /// of 8 to 128 characters. Every other email is refused.
    static let signUpEmail = "new.user@example.com"
    static let sessionToken = "synthetic-session-token"

    static let mentalHealthID = "8d7b4f0e-0000-4000-8000-000000000310"
    static let fundamentalsID = "8d7b4f0e-0000-4000-8000-000000000220"
    static let semester1ID = "8d7b4f0e-0000-4000-8000-000000000001"
    static let semester2ID = "8d7b4f0e-0000-4000-8000-000000000002"

    struct Account {
        let id: String
        let email: String
        let name: String
        var password: String
        var mustChangePassword: Bool
        /// Her color scheme, "dusk" until she picks "slate" in Settings.
        var palette = "dusk"
        var role = "student"

        var json: [String: Any] {
            ["id": id, "email": email, "name": name, "role": role, "mustChangePassword": mustChangePassword, "palette": palette]
        }
    }

    struct FakeSemester {
        let id: String
        let number: Int
        var name: String
        var startsOn: String?
        var endsOn: String?
        /// Set by hand in Settings; nothing archives a semester on its own.
        var archivedAt: String?
    }

    /// A course with the counts Home shows. Courses added in Settings start at zero. A study topic
    /// is one too, of kind "topic", with no semester and no code.
    struct FakeCourse {
        let id: String
        var kind = "course"
        /// Empty for a topic.
        var semesterID: String
        var code: String
        var title: String
        var sortOrder: Int
        var archivedAt: String?
        var questions = 0, folders = 0, review = 0, answered = 0, right = 0, points = 0, maxPoints = 0
        /// When she deleted it, or nil. A deleted course is left out of every read until Undo.
        var deletedAt: Date?
    }

    /// A set an import wrote while the app ran.
    struct ImportedEntry {
        let courseID: String
        let title: String
        let kind: String
        let questionCount: Int
        let termCount: Int
        let importedAt: Date
        /// "imported", or "replaced" for a new version of a set.
        let status: String
        /// The version this one replaced, which Restore brings back.
        let previous: String?
        /// False once a newer version replaced it.
        var isCurrent = true
    }

    struct State {
        var accounts: [Account]
        var semesters: [FakeSemester]
        var courses: [FakeCourse]
        /// Bearer token to account email.
        var sessions: [String: String]
        var place: String?
        var psychosocialRestored = false
        var tokenCount = 0
        /// Saved answers by `clientAttemptId`, so a repeated send is answered with the saved one.
        var attempts: [String: Data] = [:]
        /// Her latest answer to each question: (status, answered at).
        var latest: [String: (status: String, at: Date)] = [:]
        /// Her latest saved answer to each question, as the reply gave it.
        var savedAnswers: [String: Data] = [:]
        /// Each set's latest sitting, by set id.
        var sittings: [String: FakeSitting] = [:]
        /// Sets imported while the app ran, by id.
        var imported: [String: ImportedEntry] = [:]
        var importCount = 0
        /// Refused sign-ups by email; the fifth locks that email's sign-up.
        var signUpRefusals: [String: Int] = [:]
        /// Wrong passwords to delete an account, by email; the fifth locks deleting it.
        var wrongDeletePasswords: [String: Int] = [:]
    }

    let state: Mutex<State>
    let now: Date
    /// Where her answers and sittings outlast the app, for a test that kills it and comes back.
    let answersFile: URL?
    private let offline = Mutex(false)
    /// Requests to end an exam still to lose the connection.
    private let finishesToDrop: Mutex<Int>
    /// Review, Terms, exams and the course's exams.
    let study: FakeStudy
    /// Make questions, for `maker` only.
    let questionMaker: FakeQuestionMaker
    /// Exam twins of her folders, for `maker` only.
    let twinJobs: FakeTwinJobs
    /// Connect an agent: two agents waiting under their codes, and the student's agent key.
    private let agents: FakeAgents
    /// Deleting her sets, folders and past exams, and Undo.
    private let deletions: FakeDeletions

    /// Without signal, every call fails before it reaches the server, as on a phone with no network.
    var isOffline: Bool {
        get { offline.withLock { $0 } }
        set { offline.withLock { $0 = newValue } }
    }

    /// - Parameters:
    ///   - signedIn: Starts with the session of `account`, as `sessionToken`.
    ///   - account: Who is signed in: `student`, `maker` to make questions, or `owner`, who reads the
    ///     same courses and is refused every write to them.
    ///   - makerIsSetUp: False: the server has no Claude key, so making questions is not set up yet.
    ///   - place: The course she used last, or nil for none.
    ///   - examInProgress: She left an exam over Mental Health's Weeks 1-2 going.
    ///   - examLastQuestionOpen: That exam has every question but its last answered.
    ///   - examEndsIn: That exam's time runs out this long after `now`.
    ///   - droppedFinishes: How many requests to end an exam lose the connection before one reaches
    ///     the server, as when the signal goes right after her last answer.
    ///   - matrixMultiSet: Weeks 1-3 holds one matrixmulti question instead of the mixed set.
    ///   - sataAllCorrectSet: Weeks 1-3 holds one select-all question whose every option is correct.
    init(
        signedIn: Bool, as account: Credentials = FakeQBankServer.student, makerIsSetUp: Bool = true,
        place: String? = FakeQBankServer.mentalHealthID, examInProgress: Bool = false, examLastQuestionOpen: Bool = false,
        examEndsIn: TimeInterval? = nil, droppedFinishes: Int = 0, matrixMultiSet: Bool = false,
        sataAllCorrectSet: Bool = false, now: Date = .now, answersFile: URL? = nil
    ) {
        self.now = now
        self.answersFile = answersFile
        study = FakeStudy(
            now: now, examInProgress: examInProgress, examLastQuestionOpen: examLastQuestionOpen, examEndsIn: examEndsIn,
            matrixMultiSet: matrixMultiSet, sataAllCorrectSet: sataAllCorrectSet
        )
        finishesToDrop = Mutex(droppedFinishes)
        questionMaker = FakeQuestionMaker(allowed: [Self.maker.email], isSetUp: makerIsSetUp, seededFor: Self.maker.email, now: now)
        twinJobs = FakeTwinJobs(maker: questionMaker, study: study)
        agents = FakeAgents(studentEmail: Self.student.email, now: now)
        deletions = FakeDeletions(study: study)
        state = Mutex(State(
            accounts: [
                Account(id: "fake-student", email: Self.student.email, name: "Sam Student", password: Self.student.password, mustChangePassword: false),
                Account(id: "fake-reset", email: Self.resetStudent.email, name: "Robin Reset", password: Self.resetStudent.password, mustChangePassword: true),
                Account(id: "fake-maker", email: Self.maker.email, name: "Max Maker", password: Self.maker.password, mustChangePassword: false),
                Account(id: "fake-owner", email: Self.owner.email, name: "Olive Owner", password: Self.owner.password, mustChangePassword: false, role: "admin"),
            ],
            semesters: [
                FakeSemester(id: Self.semester1ID, number: 1, name: "Semester 1"),
                FakeSemester(id: Self.semester2ID, number: 2, name: "Semester 2"),
            ],
            courses: [
                FakeCourse(id: Self.mentalHealthID, semesterID: Self.semester1ID, code: "NURS 310", title: "Mental Health", sortOrder: 1,
                           questions: 86, folders: 4, review: 12, answered: 35, right: 24, points: 61, maxPoints: 92),
                FakeCourse(id: Self.fundamentalsID, semesterID: Self.semester1ID, code: "NURS 220", title: "Fundamentals", sortOrder: 2,
                           questions: 146, folders: 3, review: 5, answered: 92, right: 70, points: 131, maxPoints: 170),
            ],
            sessions: signedIn ? [Self.sessionToken: account.email] : [:],
            place: place
        ))
        readKeptAnswers()
    }

    /// The session the app keeps for `student` when a scenario starts signed in.
    static func storedStudentSession(expiresAt: Date = .now.addingTimeInterval(30 * 86_400)) -> StoredSession {
        StoredSession(
            token: sessionToken,
            expiresAt: expiresAt,
            account: QBankKit.Account(id: "fake-student", email: student.email, name: "Sam Student", role: .student, mustChangePassword: false)
        )
    }

    /// The session the app keeps for `maker` when a scenario starts signed in as her.
    static func storedMakerSession(expiresAt: Date = .now.addingTimeInterval(30 * 86_400)) -> StoredSession {
        StoredSession(
            token: sessionToken,
            expiresAt: expiresAt,
            account: QBankKit.Account(id: "fake-maker", email: maker.email, name: "Max Maker", role: .student, mustChangePassword: false)
        )
    }

    /// The session the app keeps for `owner` when a scenario starts signed in as the owner.
    static func storedOwnerSession(expiresAt: Date = .now.addingTimeInterval(30 * 86_400)) -> StoredSession {
        StoredSession(
            token: sessionToken,
            expiresAt: expiresAt,
            account: QBankKit.Account(id: "fake-owner", email: owner.email, name: "Olive Owner", role: .admin, mustChangePassword: false)
        )
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let url = request.url ?? URL(string: "https://fake.invalid")!
        if request.httpMethod == "POST", url.path().hasPrefix("/api/exams/"), url.path().hasSuffix("/finish"),
           finishesToDrop.withLock({ left in
               guard left > 0 else { return false }
               left -= 1
               return true
           }) {
            throw URLError(.networkConnectionLost)
        }
        // A repeated parameter, such as exam setup's folderIds, keeps every value, joined by commas:
        // no id has one.
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { $0[$1.name] = [$0[$1.name], $1.value ?? ""].compactMap(\.self).joined(separator: ",") }
        let method = request.httpMethod ?? "GET"
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        let fields = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var headers = ["Content-Type": "application/json"]
        let (status, body) = answer(method: method, path: url.path(), query: query, token: token, body: fields, rawBody: request.httpBody)
        // A lock says how long in its header too, as the server's does.
        if let retryAfter = body["retryAfterSeconds"] as? Int {
            headers["retry-after"] = String(retryAfter)
        }
        // A 204 has no body, as the server sends it.
        let data = status == 204 ? Data() : try JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }

    typealias Reply = (Int, [String: Any])

    private func answer(method: String, path: String, query: [String: String], token: String?, body: [String: Any], rawBody: Data?) -> Reply {
        if method == "POST", path == "/api/sign-in/password" {
            return signIn(email: body["email"] as? String ?? "", password: body["password"] as? String ?? "")
        }
        if method == "POST", path == "/api/sign-up" {
            return signUp(email: body["email"] as? String ?? "", password: body["password"] as? String ?? "")
        }
        guard let token, let account = account(for: token) else {
            return failure(401, "unauthenticated", "Sign in to continue.")
        }
        switch (method, path) {
        case ("GET", "/api/session"):
            return (200, ["user": account.json, "expiresAt": date(days: 30)])
        case ("POST", "/api/sign-out"):
            state.withLock { _ = $0.sessions.removeValue(forKey: token) }
            return (200, ["status": "ok"])
        case ("POST", "/api/sign-out/everywhere"):
            // Every session of the account ends, this one included, as the real route ends them.
            state.withLock { state in
                state.sessions = state.sessions.filter { $0.value != account.email }
            }
            return (200, ["status": "signed_out_everywhere"])
        case ("POST", "/api/account/password"):
            return changePassword(account, token: token, current: body["currentPassword"] as? String ?? "", new: body["newPassword"] as? String ?? "")
        case ("DELETE", "/api/me"):
            return deleteAccount(account, password: body["password"] as? String ?? "")
        default:
            break
        }
        if account.mustChangePassword {
            return failure(403, "must_change_password", "Choose a new password to continue.")
        }
        if FakeAgents.handles(path) {
            return agents.answer(method: method, path: path, body: body, email: account.email)
        }
        if account.role == "admin", let reply = adminAnswer(method: method, path: path, body: body, email: account.email) {
            return reply
        }
        if let reply = courseDeletion(method: method, path: path, query: query, email: account.email) {
            return reply
        }
        if let reply = questionMaker.answer(method: method, path: path, body: body, email: account.email, library: self) {
            return reply
        }
        if let reply = twinJobs.answer(method: method, path: path, body: body, email: account.email, library: self) {
            return reply
        }
        if let reply = deletions.answer(method: method, path: path, query: query, library: self) {
            return reply
        }
        switch (method, path) {
        case ("GET", "/api/semesters"):
            return (200, catalog())
        case ("POST", "/api/topics"):
            return addTopic(title: body["title"] as? String ?? "")
        case ("PUT", "/api/topic-order"):
            return setTopicOrder(body["topicIds"] as? [String])
        case ("POST", "/api/semesters"):
            return addSemester(number: body["number"] as? Int)
        case ("POST", "/api/courses"):
            return addCourse(semesterID: body["semesterId"] as? String ?? "", code: body["code"] as? String ?? "", title: body["title"] as? String ?? "")
        case ("PATCH", _) where path.hasPrefix("/api/semesters/"):
            return updateSemester(id: String(path.dropFirst("/api/semesters/".count)), body: body)
        case ("PATCH", _) where path.hasPrefix("/api/courses/"):
            return updateCourse(id: String(path.dropFirst("/api/courses/".count)), body: body)
        case ("GET", "/api/me/place"):
            // A course she deleted is left out, so she lands on Home.
            let place = state.withLock { state in state.place.flatMap { id in state.courses.contains { $0.id == id && $0.deletedAt == nil } ? id : nil } }
            return (200, ["courseId": json(place)])
        case ("PUT", "/api/me/place"):
            let place = body["courseId"] as? String
            state.withLock { $0.place = place }
            return (200, ["courseId": json(place)])
        case ("PUT", "/api/me/palette"):
            return setPalette(account, to: body["palette"] as? String)
        case ("GET", "/api/courses/\(Self.mentalHealthID)"):
            return (200, mentalHealth().merging(stored(Self.mentalHealthID)) { _, edited in edited }.merging(studied(Self.mentalHealthID)) { _, now in now })
        case ("GET", "/api/courses/\(Self.fundamentalsID)"):
            return (200, fundamentals().merging(stored(Self.fundamentalsID)) { _, edited in edited }.merging(studied(Self.fundamentalsID)) { _, now in now })
        case ("GET", _) where path.hasPrefix("/api/courses/") && path.split(separator: "/").count == 3:
            return plainCourse(String(path.dropFirst("/api/courses/".count)))
        case ("POST", "/api/imports/check"):
            return (200, FakeImportCheck(source: body["source"] as? String ?? "").json)
        case ("POST", "/api/imports"):
            return importSet(body)
        case ("POST", "/api/practice-sets/psychosocial-v2/restore"):
            let restored = state.withLock { state -> Bool in
                defer { state.psychosocialRestored = true }
                return state.psychosocialRestored
            }
            if restored { return failure(404, "request_refused", "That set is not the current version.") }
            study.replace(set: "psychosocial-v2", with: "psychosocial-v1")
            return (200, set("psychosocial-v1"))
        case ("POST", "/api/attempts"):
            return recordAttempt(rawBody)
        default:
            break
        }
        if method == "POST", path.hasPrefix("/api/practice-sets/"), path.hasSuffix("/start-over") {
            return startOver(String(path.dropFirst("/api/practice-sets/".count).dropLast("/start-over".count)))
        }
        if method == "POST", path.hasPrefix("/api/practice-sets/"), path.hasSuffix("/restore") {
            return restoreImported(String(path.dropFirst("/api/practice-sets/".count).dropLast("/restore".count)))
        }
        if method == "GET", path.hasPrefix("/api/practice-sets/") {
            return practiceSet(id: String(path.dropFirst("/api/practice-sets/".count)))
        }
        if let reply = study.answer(method: method, path: path, query: query, body: body, folderJSON: folderJSON) {
            return reply
        }
        return failure(404, "request_refused", "That is not in the app.")
    }

    // MARK: Plumbing

    func date(days: Int) -> String {
        QBankJSON.formatDate(now.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    /// A JSON value that is null when nil.
    func json(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }
}
#endif
