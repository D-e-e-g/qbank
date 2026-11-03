#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// An in-process stand-in for the QBank server, for UI tests and simulator review. It answers the
/// app's calls with invented accounts, courses and questions, the way the real routes answer them,
/// and scores answers with the server's rules, so the app runs end to end through `QBankClient`
/// without a network or a real account.
nonisolated final class FakeQBankServer: HTTPTransport, FakeQuestionLibrary, FakeDeletionLibrary {
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
    /// The one email on the owner's sign-up list, with no account yet: it signs up with any password
    /// of 8 to 128 characters. Every other email is refused.
    static let signUpEmail = "new.user@example.com"
    static let sessionToken = "synthetic-session-token"

    static let mentalHealthID = "8d7b4f0e-0000-4000-8000-000000000310"
    static let fundamentalsID = "8d7b4f0e-0000-4000-8000-000000000220"
    static let semester1ID = "8d7b4f0e-0000-4000-8000-000000000001"
    static let semester2ID = "8d7b4f0e-0000-4000-8000-000000000002"

    private struct Account {
        let id: String
        let email: String
        let name: String
        var password: String
        var mustChangePassword: Bool
        /// Her color scheme, "dusk" until she picks "slate" in Settings.
        var palette = "dusk"

        var json: [String: Any] {
            ["id": id, "email": email, "name": name, "role": "student", "mustChangePassword": mustChangePassword, "palette": palette]
        }
    }

    private struct FakeSemester {
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
    private struct FakeCourse {
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
    private struct ImportedEntry {
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

    private struct State {
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
        /// Sets imported while the app ran, by id.
        var imported: [String: ImportedEntry] = [:]
        var importCount = 0
        /// Refused sign-ups by email; the fifth locks that email's sign-up.
        var signUpRefusals: [String: Int] = [:]
        /// Wrong passwords to delete an account, by email; the fifth locks deleting it.
        var wrongDeletePasswords: [String: Int] = [:]
    }

    private let state: Mutex<State>
    private let now: Date
    private let offline = Mutex(false)
    /// Review, Terms, exams and the course's exams.
    private let study: FakeStudy
    /// Make questions, for `maker` only.
    private let questionMaker: FakeQuestionMaker
    /// Exam twins of her folders, for `maker` only.
    private let twinJobs: FakeTwinJobs
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
    ///   - account: Who is signed in: `student`, or `maker` to make questions.
    ///   - makerIsSetUp: False: the server has no Claude key, so making questions is not set up yet.
    ///   - place: The course she used last, or nil for none.
    ///   - examInProgress: She left an exam over Mental Health's Weeks 1-2 going.
    init(
        signedIn: Bool, as account: Credentials = FakeQBankServer.student, makerIsSetUp: Bool = true,
        place: String? = FakeQBankServer.mentalHealthID, examInProgress: Bool = false, now: Date = .now
    ) {
        self.now = now
        study = FakeStudy(now: now, examInProgress: examInProgress)
        questionMaker = FakeQuestionMaker(allowed: [Self.maker.email], isSetUp: makerIsSetUp, seededFor: Self.maker.email, now: now)
        twinJobs = FakeTwinJobs(maker: questionMaker, study: study)
        agents = FakeAgents(studentEmail: Self.student.email, now: now)
        deletions = FakeDeletions(study: study)
        state = Mutex(State(
            accounts: [
                Account(id: "fake-student", email: Self.student.email, name: "Sam Student", password: Self.student.password, mustChangePassword: false),
                Account(id: "fake-reset", email: Self.resetStudent.email, name: "Robin Reset", password: Self.resetStudent.password, mustChangePassword: true),
                Account(id: "fake-maker", email: Self.maker.email, name: "Max Maker", password: Self.maker.password, mustChangePassword: false),
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

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let url = request.url ?? URL(string: "https://fake.invalid")!
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

    private typealias Reply = (Int, [String: Any])

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
        if let reply = courseDeletion(method: method, path: path, query: query, email: account.email) {
            return reply
        }
        if let reply = questionMaker.answer(method: method, path: path, body: body, email: account.email, library: self) {
            return reply
        }
        if let reply = twinJobs.answer(method: method, path: path, body: body, email: account.email, library: self) {
            return reply
        }
        if let reply = deletions.answer(method: method, path: path, query: query, isStudent: true, library: self) {
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

    // MARK: Accounts

    private func account(for token: String) -> Account? {
        state.withLock { state in
            state.sessions[token].flatMap { email in state.accounts.first { $0.email == email } }
        }
    }

    private func signIn(email: String, password: String) -> Reply {
        let normalized = email.lowercased()
        return startSession { $0.email == normalized && $0.password == password }
    }

    /// A user account for the email on the sign-up list, signed in at once, as the real route makes
    /// it: the fields' rules first, then the lock, then the list. Any other email, or one that has
    /// an account, gets the same refusal, and the fifth refusal locks that email's sign-up.
    private func signUp(email: String, password: String) -> Reply {
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
    private func deleteAccount(_ account: Account, password: String) -> Reply {
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
    private func setPalette(_ account: Account, to palette: String?) -> Reply {
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

    private func changePassword(_ account: Account, token: String, current: String, new: String) -> Reply {
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

    // MARK: Courses

    /// Her semesters with their courses, and her study topics in her order.
    private func catalog() -> [String: Any] {
        state.withLock { state in
            [
                "semesters": state.semesters.sorted { $0.number < $1.number }.map { semesterJSON($0, in: state) },
                "topics": Self.topics(in: state).map { courseJSON($0, in: state) },
            ]
        }
    }

    /// Her topics in her order, without the ones she deleted.
    private static func topics(in state: State) -> [FakeCourse] {
        state.courses.filter { $0.kind == "topic" && $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func semesterJSON(_ semester: FakeSemester, in state: State) -> [String: Any] {
        [
            "id": semester.id, "number": semester.number, "name": semester.name,
            "startsOn": json(semester.startsOn), "endsOn": json(semester.endsOn), "archivedAt": json(semester.archivedAt),
            "courses": state.courses.filter { $0.kind == "course" && $0.semesterID == semester.id && $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }.map { courseJSON($0, in: state) },
        ]
    }

    private func courseJSON(_ course: FakeCourse, in state: State) -> [String: Any] {
        let added = Self.added(courseID: course.id, latest: state.latest)
        // The two studied courses count the folders she has now; the others, their invented count.
        let folders = study.knows(course.id) ? study.folders(course.id) : nil
        return [
            "id": course.id, "kind": course.kind, "code": course.code, "title": course.title, "sortOrder": course.sortOrder,
            "archivedAt": json(course.archivedAt),
            "questionCount": course.questions + importedQuestions(course.id, in: state),
            "weekCount": folders.map { Set($0.filter { !$0.sets.isEmpty }.map(\.name)).count } ?? course.folders,
            "folderCount": folders?.count ?? course.folders,
            "reviewCount": FakeStudy.codes[course.id] == nil ? course.review : study.reviewCount(course.id),
            "answeredCount": course.answered + added.answered, "fullyRightCount": course.right + added.right,
            "points": course.points, "maxPoints": course.maxPoints,
        ]
    }

    /// Progress she made before the scenario starts, by set: questions answered, fully right, and
    /// days since her last answer.
    private static let earlierProgress: [String: (answered: Int, right: Int, lastAnsweredDaysAgo: Int)] = [
        "rights-v1": (17, 13, 9),
        "communication-v1": (9, 6, 1),
        "vitals-v1": (43, 35, 1),
        "safety-v1": (42, 30, 1),
        "mobility-v1": (7, 5, 1),
    ]

    /// Every set of each course, in all its versions.
    private static let setsByCourse: [String: Set<String>] = [
        mentalHealthID: ["rights-v1", "communication-v1", "psychosocial-v1", "psychosocial-v2", "depression-v1", "anxiety-v1", "mixed-v1"],
        fundamentalsID: ["vitals-v1", "safety-v1", "mobility-v1"],
    ]

    /// What her answers here add to a course's invented counts. A set she answered here counts her
    /// answers instead of its earlier progress, as the set's own line does.
    private static func added(courseID: String, latest: [String: (status: String, at: Date)]) -> (answered: Int, right: Int) {
        let sets = setsByCourse[courseID] ?? []
        var bySet: [String: [String]] = [:]
        for (questionID, answer) in latest {
            let setID = questionID.split(separator: "-").dropLast().joined(separator: "-")
            if sets.contains(setID) {
                bySet[setID, default: []].append(answer.status)
            }
        }
        return bySet.reduce(into: (0, 0)) { total, entry in
            let earlier = earlierProgress[entry.key]
            total.0 += entry.value.count - (earlier?.answered ?? 0)
            total.1 += entry.value.count { $0 == "correct" } - (earlier?.right ?? 0)
        }
    }

    // MARK: Editing semesters and courses, with the content service's rules and words

    private func addSemester(number: Int?) -> Reply {
        guard let number, (1...3).contains(number) else {
            return failure(400, "request_refused", "A semester is 1, 2, or 3.")
        }
        return state.withLock { state -> Reply in
            guard !state.semesters.contains(where: { $0.number == number }) else {
                return failure(409, "request_refused", "Semester \(number) already exists.")
            }
            let semester = FakeSemester(id: "8d7b4f0e-0000-4000-8000-00000000000\(number)", number: number, name: "Semester \(number)")
            state.semesters.append(semester)
            return (201, semesterJSON(semester, in: state))
        }
    }

    private func updateSemester(id: String, body: [String: Any]) -> Reply {
        state.withLock { state -> Reply in
            guard let index = state.semesters.firstIndex(where: { $0.id == id }) else {
                return failure(404, "request_refused", "That semester is not in the app.")
            }
            var semester = state.semesters[index]
            if let name = body["name"] as? String {
                guard let text = requiredText(name, label: "Semester name", maxLength: 80) else {
                    return failure(400, "request_refused", textProblem(name, label: "Semester name"))
                }
                semester.name = text
            }
            for (key, label) in [("startsOn", "Start date"), ("endsOn", "End date")] where body.keys.contains(key) {
                let value = body[key] as? String
                if let value, !value.isEmpty, value.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) == nil {
                    return failure(400, "request_refused", "\(label) has to be a date like 2026-09-01.")
                }
                let date = value?.isEmpty == false ? value : nil
                if key == "startsOn" { semester.startsOn = date } else { semester.endsOn = date }
            }
            if let archived = body["archived"] as? Bool {
                semester.archivedAt = archived ? QBankJSON.formatDate(.now) : nil
            }
            state.semesters[index] = semester
            return (200, semesterJSON(semester, in: state))
        }
    }

    private func addCourse(semesterID: String, code: String, title: String) -> Reply {
        state.withLock { state -> Reply in
            guard state.semesters.contains(where: { $0.id == semesterID }) else {
                return failure(404, "request_refused", "That semester is not in the app.")
            }
            guard let code = requiredText(code, label: "Course code", maxLength: 32) else {
                return failure(400, "request_refused", textProblem(code, label: "Course code"))
            }
            guard let title = requiredText(title, label: "Course name", maxLength: 160) else {
                return failure(400, "request_refused", textProblem(title, label: "Course name"))
            }
            if let taken = codeTaken(code, in: semesterID, except: nil, courses: state.courses) { return taken }
            state.tokenCount += 1
            let order = (state.courses.filter { $0.semesterID == semesterID }.map(\.sortOrder).max() ?? 0) + 1
            let course = FakeCourse(
                id: String(format: "8d7b4f0e-0000-4000-8000-%012d", 900 + state.tokenCount),
                semesterID: semesterID, code: code, title: title, sortOrder: order
            )
            state.courses.append(course)
            return (201, courseJSON(course, in: state))
        }
    }

    private func updateCourse(id: String, body: [String: Any]) -> Reply {
        state.withLock { state -> Reply in
            guard let index = state.courses.firstIndex(where: { $0.id == id }) else {
                return failure(404, "request_refused", "That course is not in the app.")
            }
            var course = state.courses[index]
            if course.kind == "topic" {
                switch updateTopic(course, body: body, in: state) {
                case .success(let edited):
                    state.courses[index] = edited
                    return (200, courseJSON(edited, in: state))
                case .failure(let refusal):
                    return refusal.reply
                }
            }
            if let code = body["code"] as? String {
                guard let text = requiredText(code, label: "Course code", maxLength: 32) else {
                    return failure(400, "request_refused", textProblem(code, label: "Course code"))
                }
                course.code = text
            }
            if let title = body["title"] as? String {
                guard let text = requiredText(title, label: "Course name", maxLength: 160) else {
                    return failure(400, "request_refused", textProblem(title, label: "Course name"))
                }
                course.title = text
            }
            if let semesterID = body["semesterId"] as? String, semesterID != course.semesterID {
                guard state.semesters.contains(where: { $0.id == semesterID }) else {
                    return failure(404, "request_refused", "That semester is not in the app.")
                }
                course.semesterID = semesterID
                course.sortOrder = (state.courses.filter { $0.semesterID == semesterID }.map(\.sortOrder).max() ?? 0) + 1
            }
            if let taken = codeTaken(course.code, in: course.semesterID, except: id, courses: state.courses) { return taken }
            if let archived = body["archived"] as? Bool {
                course.archivedAt = archived ? QBankJSON.formatDate(.now) : nil
            }
            state.courses[index] = course
            return (200, courseJSON(course, in: state))
        }
    }

    // MARK: Study topics, with the content service's rules

    private func addTopic(title: String) -> Reply {
        state.withLock { state -> Reply in
            guard let text = requiredText(title, label: "Topic name", maxLength: 160) else {
                return failure(400, "request_refused", textProblem(title, label: "Topic name"))
            }
            if let taken = topicTaken(text, except: nil, in: state) { return taken.reply }
            state.tokenCount += 1
            let topic = FakeCourse(
                id: String(format: "7a0e0000-0000-4000-8000-%012d", 900 + state.tokenCount), kind: "topic",
                semesterID: "", code: "", title: text, sortOrder: (Self.topics(in: state).map(\.sortOrder).max() ?? 0) + 1
            )
            state.courses.append(topic)
            study.register(course: topic.id)
            return (201, courseJSON(topic, in: state))
        }
    }

    /// Refuses a list that does not name exactly her topics, archived ones too, once each.
    private func setTopicOrder(_ ids: [String]?) -> Reply {
        state.withLock { state -> Reply in
            let topics = Self.topics(in: state)
            guard let ids, ids.count == topics.count, Set(ids) == Set(topics.map(\.id)) else {
                return failure(409, "request_refused", "Your topics changed. Reload and try again.")
            }
            for (position, id) in ids.enumerated() {
                guard let index = state.courses.firstIndex(where: { $0.id == id }) else { continue }
                state.courses[index].sortOrder = position + 1
            }
            return (200, ["topics": Self.topics(in: state).map { courseJSON($0, in: state) }])
        }
    }

    /// A topic takes its name and archiving only.
    private func updateTopic(_ topic: FakeCourse, body: [String: Any], in state: State) -> Result<FakeCourse, FakeStudy.Failure> {
        if body["code"] != nil || body["semesterId"] != nil {
            return .failure(FakeStudy.Failure(status: 400, message: "A topic has no code or semester."))
        }
        var edited = topic
        if let title = body["title"] as? String {
            guard let text = requiredText(title, label: "Topic name", maxLength: 160) else {
                return .failure(FakeStudy.Failure(status: 400, message: textProblem(title, label: "Topic name")))
            }
            if let taken = topicTaken(text, except: topic.id, in: state) { return .failure(taken) }
            edited.title = text
        }
        if let archived = body["archived"] as? Bool {
            edited.archivedAt = archived ? QBankJSON.formatDate(.now) : nil
        }
        return .success(edited)
    }

    private func topicTaken(_ title: String, except id: String?, in state: State) -> FakeStudy.Failure? {
        let taken = Self.topics(in: state).contains { $0.id != id && $0.title.lowercased() == title.lowercased() }
        return taken ? FakeStudy.Failure(status: 409, message: "You already have a topic named \(title).") : nil
    }

    private func requiredText(_ value: String, label: String, maxLength: Int) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > maxLength ? nil : text
    }

    private func textProblem(_ value: String, label: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(label) is required." : "\(label) is too long."
    }

    private func codeTaken(_ code: String, in semesterID: String, except id: String?, courses: [FakeCourse]) -> Reply? {
        let taken = courses.contains { $0.semesterID == semesterID && $0.id != id && $0.deletedAt == nil && $0.code.lowercased() == code.lowercased() }
        return taken ? failure(409, "request_refused", "This semester already has a course with the code \(code).") : nil
    }

    /// The fields a course's detail shares with Settings, which can rename and move it.
    private func stored(_ id: String) -> [String: Any] {
        state.withLock { state in
            let course = state.courses.first { $0.id == id }!
            let semester = state.semesters.first { $0.id == course.semesterID }
            return [
                "id": course.id, "kind": course.kind, "code": course.code, "title": course.title, "archivedAt": json(course.archivedAt),
                "semester": semester.map { ["id": $0.id, "number": $0.number, "name": $0.name] as Any } ?? NSNull(),
            ]
        }
    }

    /// What a course's detail says about her study: its exams, and her Review and terms counts.
    private func studied(_ id: String) -> [String: Any] {
        ["exams": study.courseExamsJSON(id), "reviewCount": study.reviewCount(id), "termCount": study.termCount(id)]
    }

    private func mentalHealth() -> [String: Any] {
        let (added, imported) = state.withLock { (Self.added(courseID: Self.mentalHealthID, latest: $0.latest), importedQuestions(Self.mentalHealthID, in: $0)) }
        return [
            "id": Self.mentalHealthID, "code": "NURS 310", "title": "Mental Health", "archivedAt": NSNull(),
            "semester": ["id": "fake-semester-1", "number": 1, "name": "Semester 1"],
            "questionCount": 86 + imported, "examQuestionCount": 134 + imported,
            "examTimeLimitSeconds": FakeStudy.examTime(questionCount: 134 + imported), "termCount": 180, "reviewCount": 12,
            "answeredCount": 35 + added.answered, "fullyRightCount": 24 + added.right, "points": 61, "maxPoints": 92,
        ].merging(folders(Self.mentalHealthID)) { _, folders in folders }
    }

    private func fundamentals() -> [String: Any] {
        let (added, imported) = state.withLock { (Self.added(courseID: Self.fundamentalsID, latest: $0.latest), importedQuestions(Self.fundamentalsID, in: $0)) }
        return [
            "id": Self.fundamentalsID, "code": "NURS 220", "title": "Fundamentals", "archivedAt": NSNull(),
            "semester": ["id": "fake-semester-1", "number": 1, "name": "Semester 1"],
            "questionCount": 146 + imported, "examQuestionCount": 146 + imported,
            "examTimeLimitSeconds": FakeStudy.examTime(questionCount: 146 + imported), "termCount": 212, "reviewCount": 5,
            "answeredCount": 92 + added.answered, "fullyRightCount": 70 + added.right, "points": 131, "maxPoints": 170,
        ].merging(folders(Self.fundamentalsID)) { _, folders in folders }
    }

    /// A course's folders with their sets, and the same sets by folder name for an app from before
    /// folders, as the server sends both.
    private func folders(_ courseID: String) -> [String: Any] {
        let folders = study.folders(courseID)
        var weeks: [[String: Any]] = []
        for folder in folders.sorted(by: { Self.weekOrder($0.name, $1.name) }) {
            let sets = folder.sets.map(set)
            if let index = weeks.firstIndex(where: { $0["label"] as? String == folder.name }) {
                weeks[index]["sets"] = (weeks[index]["sets"] as? [[String: Any]] ?? []) + sets
                weeks[index]["examBankCount"] = (weeks[index]["examBankCount"] as? Int ?? 0) + folder.bank.count
            } else {
                weeks.append(["label": folder.name, "sets": sets, "examBankCount": folder.bank.count])
            }
        }
        return [
            "folders": folders.map(folderJSON),
            "folderCount": folders.count,
            "weeks": weeks,
            "weekCount": weeks.count { !(($0["sets"] as? [[String: Any]]) ?? []).isEmpty },
        ]
    }

    /// A folder as the server sends it, with its sets and its exam bank's sets.
    private func folderJSON(_ folder: FakeStudy.Folder) -> [String: Any] {
        [
            "id": folder.id, "name": folder.name, "examPageId": json(folder.examPageID), "sortOrder": folder.sortOrder,
            "sets": folder.sets.map(set), "examBankCount": folder.bank.count,
            "examSets": FakeStudy.examSets(folder)
                .map { ["id": $0.id, "title": examSetTitle($0.id), "questionCount": $0.questionIDs.count] }
                .sorted { ($0["title"] as? String ?? "").localizedCompare($1["title"] as? String ?? "") == .orderedAscending },
        ]
    }

    /// The server's week order (`compareWeeks`): by the first number in the name, then by name.
    private static func weekOrder(_ a: String, _ b: String) -> Bool {
        let rank = { (name: String) in name.firstMatch(of: /\d+/).flatMap { Int($0.output) } ?? Int.max }
        let (left, right) = (rank(a), rank(b))
        return left == right ? a.localizedCompare(b) == .orderedAscending : left < right
    }

    /// Every set of the invented courses: title, size, how many days ago it arrived, and how.
    private static let catalog: [String: (title: String, questions: Int, daysAgo: Int, status: String, canRestore: Bool)] = [
        "rights-v1": ("Rights, Law, and Ethics", 17, 20, "imported", false),
        "communication-v1": ("Therapeutic Communication and the Relationship", 14, 12, "imported", false),
        "psychosocial-v2": ("Psychosocial Assessment and Safety Screening", 12, 6, "replaced", true),
        "psychosocial-v1": ("Psychosocial Assessment and Safety Screening", 12, 0, "restored", true),
        "depression-v1": ("Depression and Antidepressants", 18, 0, "imported", false),
        "anxiety-v1": ("Anxiety, Panic, and Anxiolytics", 13, 0, "imported", false),
        "mixed-v1": ("Mixed Clinical Judgment", 8, 4, "imported", false),
        "vitals-v1": ("Vital Signs Under Pressure", 43, 30, "imported", false),
        "safety-v1": ("Safety and Infection Control", 42, 22, "imported", false),
        "mobility-v1": ("Mobility and Skin Integrity", 61, 8, "imported", false),
    ]

    /// A set's title, size, when it arrived and how, from the invented catalog or an import.
    private func summary(of id: String) -> (title: String, questions: Int, importedAt: Date, status: String, canRestore: Bool)? {
        if let entry = Self.catalog[id] {
            return (entry.title, entry.questions, now.addingTimeInterval(TimeInterval(-entry.daysAgo) * 86_400), entry.status, entry.canRestore)
        }
        return state.withLock { state in
            state.imported[id].map { ($0.title, $0.questionCount, $0.importedAt, $0.status, $0.previous != nil) }
        }
    }

    private func set(_ id: String) -> [String: Any] {
        let entry = summary(of: id) ?? ("Invented set", 0, now, "imported", false)
        let earlier = Self.earlierProgress[id]
        let questionIDs = (0..<entry.questions).map { "\(id)-q\($0)" }
        // Once she answers here, the set's line counts her answers, as the server's does.
        let latest = state.withLock { state in questionIDs.compactMap { state.latest[$0] } }
        var json: [String: Any] = [
            "id": id, "title": entry.title, "description": "", "questionCount": entry.questions,
            "importedAt": QBankJSON.formatDate(entry.importedAt), "activeSince": QBankJSON.formatDate(entry.importedAt),
            "status": entry.status, "canRestore": entry.canRestore, "questionIds": questionIDs,
            "importedByAgent": FakeAgents.importer(ofSet: id) ?? NSNull(),
        ]
        if latest.isEmpty {
            json["answeredCount"] = earlier?.answered ?? 0
            json["fullyRightCount"] = earlier?.right ?? 0
            json["lastAnsweredAt"] = self.json(earlier.map { date(days: -$0.lastAnsweredDaysAgo) })
        } else {
            json["answeredCount"] = latest.count
            json["fullyRightCount"] = latest.count { $0.status == "correct" }
            json["lastAnsweredAt"] = QBankJSON.formatDate(latest.map(\.at).max() ?? now)
        }
        return json
    }

    // MARK: Import, with the rules and words of `content/service.ts` `commitImport`

    /// A course that is not one of the two studied ones, such as one Settings or an import added.
    private func plainCourse(_ id: String) -> Reply {
        let imported = state.withLock { state -> Int? in
            state.courses.contains { $0.id == id } ? importedQuestions(id, in: state) : nil
        }
        guard let imported else { return failure(404, "request_refused", "That course is not in the app.") }
        let counts: [String: Any] = [
            "questionCount": imported, "examQuestionCount": imported, "examTimeLimitSeconds": FakeStudy.examTime(questionCount: imported),
            "answeredCount": 0, "fullyRightCount": 0, "points": 0, "maxPoints": 0,
        ]
        return (200, counts.merging(folders(id)) { _, folders in folders }.merging(stored(id)) { _, stored in stored }.merging(studied(id)) { _, now in now })
    }

    /// The questions of a course's current imported practice sets.
    private func importedQuestions(_ courseID: String, in state: State) -> Int {
        state.imported.values.filter { $0.courseID == courseID && $0.isCurrent && $0.kind == "practice" }.reduce(0) { $0 + $1.questionCount }
    }

    private func importSet(_ body: [String: Any]) -> Reply {
        let source = body["source"] as? String ?? ""
        let check = FakeImportCheck(source: source)
        guard check.ok, let fileTitle = check.title else {
            return (400, [
                "error": "invalid_import", "message": check.errors.first ?? "This file can't be imported.",
                "errors": check.errors, "warnings": check.warnings,
            ])
        }
        var title = fileTitle
        if let given = body["title"] as? String {
            title = given.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return failure(400, "request_refused", "Set name is required.") }
        }
        let courseID = body["courseId"] as? String, newCourse = body["newCourse"] as? [String: Any]
        let newTopic = body["newTopic"] as? [String: Any]
        let folderID = body["folderId"] as? String
        let folderName = ((body["folderName"] ?? body["weekLabel"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = [courseID != nil, newCourse != nil, newTopic != nil].count { $0 }
        if chosen > 1 { return failure(400, "request_refused", "Choose a course, a new course or a new topic, not more than one.") }
        if chosen == 0 { return failure(400, "request_refused", "Choose a course.") }
        if folderID != nil, folderName != nil { return failure(400, "request_refused", "Choose a folder or a folder name, not both.") }
        if folderID != nil, newCourse != nil || newTopic != nil {
            return failure(400, "request_refused", "A new course has no folders yet. Name a folder, or leave it for Unsorted.")
        }
        if let folderName, folderName.isEmpty { return failure(400, "request_refused", "Folder name is required.") }
        let course: FakeCourse
        if let newCourse {
            switch makeCourse(newCourse) {
            case .success(let made): course = made
            case .failure(let refusal): return refusal.reply
            }
        } else if let newTopic {
            let (status, made) = addTopic(title: newTopic["title"] as? String ?? "")
            guard status == 201, let id = made["id"] as? String, let topic = state.withLock({ state in state.courses.first { $0.id == id } }) else {
                return (status, made)
            }
            course = topic
        } else if let known = state.withLock({ state in state.courses.first { $0.id == courseID && $0.deletedAt == nil } }) {
            course = known
        } else {
            return failure(404, "request_refused", "That course is not in the app.")
        }
        let decision = body["decision"] as? String ?? "import"
        let existing = currentSet(in: course.id, kind: check.kind, title: title)
        if let existing, decision == "import", let folder = existingFolder(of: existing) {
            return (409, [
                "conflict": true, "title": title, "courseId": course.id, "courseCode": course.code, "courseTitle": course.title,
                "weekLabel": folder.name, "folderId": folder.id, "folderName": folder.name,
                "existingQuestionCount": summary(of: existing)?.questions ?? 0, "incomingQuestionCount": check.questionCount, "setId": existing,
            ])
        }
        let replace = decision == "replace" ? existing : nil
        let folder: FakeStudy.Folder
        if let replace, let current = existingFolder(of: replace) {
            folder = current
        } else {
            switch study.importFolder(courseID: course.id, folderID: folderID, folderName: folderName) {
            case .success(let found): folder = found
            case .failure(let refusal): return refusal.reply
            }
        }
        let id = state.withLock { state -> String in
            state.importCount += 1
            let id = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            if let replace { state.imported[replace]?.isCurrent = false }
            state.imported[id] = ImportedEntry(
                courseID: course.id, title: title, kind: check.kind, questionCount: check.questionCount, termCount: check.termCount,
                importedAt: .now, status: replace == nil ? "imported" : "replaced", previous: replace
            )
            return id
        }
        if check.kind == "exam" {
            study.file(bank: FakeStudy.ids("bank-\(id)", check.questionCount), in: folder.id)
        } else {
            study.file(set: id, in: folder.id, replacing: replace, questionCount: check.questionCount)
        }
        let page = study.folders(course.id).first { $0.id == folder.id }?.examPageID
        return (201, [
            "kind": replace == nil ? "imported" : "replaced", "setKind": check.kind, "setId": id, "courseId": course.id,
            "courseCode": course.code, "title": title, "weekLabel": folder.name, "folderId": folder.id, "folderName": folder.name,
            "examPageId": json(page), "questionCount": check.questionCount, "termCount": check.termCount, "warnings": check.warnings,
        ])
    }

    /// A course an import makes, in the semester of that number, made too when it is missing.
    private func makeCourse(_ body: [String: Any]) -> Result<FakeCourse, FakeStudy.Failure> {
        state.withLock { state in
            guard let code = requiredText(body["code"] as? String ?? "", label: "Course code", maxLength: 32) else {
                return .failure(FakeStudy.Failure(status: 400, message: textProblem(body["code"] as? String ?? "", label: "Course code")))
            }
            guard let title = requiredText(body["title"] as? String ?? "", label: "Course name", maxLength: 160) else {
                return .failure(FakeStudy.Failure(status: 400, message: textProblem(body["title"] as? String ?? "", label: "Course name")))
            }
            guard let number = body["semesterNumber"] as? Int, (1...3).contains(number) else {
                return .failure(FakeStudy.Failure(status: 400, message: "A semester is 1, 2, or 3."))
            }
            if !state.semesters.contains(where: { $0.number == number }) {
                state.semesters.append(FakeSemester(id: "8d7b4f0e-0000-4000-8000-00000000000\(number)", number: number, name: "Semester \(number)"))
            }
            let semesterID = state.semesters.first { $0.number == number }!.id
            if let taken = codeTaken(code, in: semesterID, except: nil, courses: state.courses) {
                return .failure(FakeStudy.Failure(status: taken.0, message: taken.1["message"] as? String ?? ""))
            }
            state.tokenCount += 1
            let course = FakeCourse(
                id: String(format: "8d7b4f0e-0000-4000-8000-%012d", 900 + state.tokenCount), semesterID: semesterID, code: code, title: title,
                sortOrder: (state.courses.filter { $0.semesterID == semesterID }.map(\.sortOrder).max() ?? 0) + 1
            )
            state.courses.append(course)
            return .success(course)
        }
    }

    /// The course's current set of this kind and name, ignoring case.
    private func currentSet(in courseID: String, kind: String, title: String) -> String? {
        let practice = study.folders(courseID).flatMap(\.sets)
        let exams = state.withLock { state in
            state.imported.filter { $0.value.courseID == courseID && $0.value.kind == "exam" && $0.value.isCurrent }.map(\.key)
        }
        let candidates = kind == "exam" ? exams : practice
        return candidates.first { summary(of: $0)?.title.lowercased() == title.lowercased() }
    }

    /// The folder a current set, or an imported exam set, is in.
    private func existingFolder(of setID: String) -> FakeStudy.Folder? {
        if let folder = study.folder(holding: setID) { return folder }
        guard let courseID = state.withLock({ $0.imported[setID]?.courseID }) else { return nil }
        return study.folders(courseID).first { $0.bank.contains { $0.hasPrefix("bank-\(setID)-") } }
    }

    /// Brings back the version an imported set replaced.
    private func restoreImported(_ id: String) -> Reply {
        let previous = state.withLock { state -> String? in
            guard let entry = state.imported[id], entry.isCurrent, let previous = entry.previous else { return nil }
            state.imported[id]?.isCurrent = false
            state.imported[previous]?.isCurrent = true
            return previous
        }
        guard let previous else { return failure(404, "request_refused", "That set is not the current version.") }
        study.replace(set: id, with: previous)
        return (200, set(previous))
    }

    // MARK: Practice

    /// A set of either course, its questions drawn from `FakePracticeQuestions`.
    private func practiceSet(id: String) -> Reply {
        guard let (courseID, folder) = find(set: id), let entry = summary(of: id) else {
            return failure(404, "request_refused", "That set is not in the app.")
        }
        return (200, [
            "id": id, "courseId": courseID, "title": entry.title, "weekLabel": folder.name, "folderId": folder.id,
            "kind": "practice",
            "questions": (0..<entry.questions).map { FakePracticeQuestions.question(setID: id, index: $0) },
        ])
    }

    /// The course and folder a current set is in.
    private func find(set id: String) -> (courseID: String, folder: FakeStudy.Folder)? {
        for courseID in state.withLock({ $0.courses.map(\.id) }) {
            if let folder = study.folders(courseID).first(where: { $0.sets.contains(id) }) {
                return (courseID, folder)
            }
        }
        return nil
    }

    /// Scores an answer with the server's rules and saves it. A repeated `clientAttemptId` gets the
    /// saved attempt back with `replayed`, as on the server.
    private func recordAttempt(_ rawBody: Data?) -> Reply {
        guard let rawBody, let submission = try? JSONDecoder().decode(FakeSubmission.self, from: rawBody) else {
            return failure(400, "invalid_request", "That answer could not be read.")
        }
        if let data = state.withLock({ $0.attempts[submission.clientAttemptId] }),
           var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            saved["replayed"] = true
            return (200, saved)
        }
        if let session = submission.studySessionId {
            let (status, saved) = study.examAnswer(
                sessionID: session, clientAttemptID: submission.clientAttemptId, questionID: submission.questionId,
                response: submission.response, guessed: submission.guessed, shuffle: submission.shuffle
            )
            if status == 201, let record = try? JSONSerialization.data(withJSONObject: saved) {
                state.withLock { $0.attempts[submission.clientAttemptId] = record }
            }
            return (status, saved)
        }
        guard let template = FakePracticeQuestions.template(forQuestionID: submission.questionId),
              let data = try? JSONSerialization.data(withJSONObject: template.merging(
                  ["id": submission.questionId, "publicId": "Q", "position": 1], uniquingKeysWith: { $1 })),
              let question = try? QBankJSON.decoder.decode(Question.self, from: data) else {
            return failure(404, "request_refused", "That question is not in the app.")
        }
        let score: Score
        do {
            score = try Scoring.score(question.body, response: submission.response)
        } catch {
            return failure(400, "invalid_request", error.message)
        }
        let answeredAt = Date.now
        // Question ids are "<set id>-q<index>".
        let setID = submission.questionId.split(separator: "-").dropLast().joined(separator: "-")
        let saved: [String: Any] = [
            "clientAttemptId": submission.clientAttemptId, "questionId": submission.questionId,
            "courseId": find(set: setID)?.courseID ?? Self.mentalHealthID,
            "status": score.status.rawValue, "points": score.points, "maxPoints": score.maxPoints,
            "guessed": submission.guessed, "answeredAt": QBankJSON.formatDate(answeredAt),
            "inReview": score.staysInReview(guessed: submission.guessed), "label": score.label, "replayed": false,
        ]
        let record = (try? JSONSerialization.data(withJSONObject: saved)) ?? Data()
        let status = score.status.rawValue
        state.withLock { state in
            state.attempts[submission.clientAttemptId] = record
            state.latest[submission.questionId] = (status, answeredAt)
        }
        if let (weekLabel, setTitle) = placeOf(questionID: submission.questionId) {
            study.practiced(
                questionID: submission.questionId, courseID: Self.mentalHealthID, score: score,
                guessed: submission.guessed, at: answeredAt, weekLabel: weekLabel, setTitle: setTitle
            )
        }
        return (201, saved)
    }

    /// The folder name and set title of a Mental Health practice question, from its set's id.
    private func placeOf(questionID: String) -> (String, String)? {
        let setID = questionID.split(separator: "-").dropLast().joined(separator: "-")
        guard let (courseID, folder) = find(set: setID), courseID == Self.mentalHealthID, let entry = Self.catalog[setID] else { return nil }
        return (folder.name, entry.title)
    }

    // MARK: Deleting a course or topic, with the rules and words of the server's `content/deletions.ts`

    /// The course delete, its Undo and Home's Recently deleted, and every other read of a deleted
    /// course, which answers as an id that names nothing; nil for any other route.
    private func courseDeletion(method: String, path: String, query: [String: String], email: String) -> Reply? {
        if method == "GET", path == "/api/deleted-courses" { return (200, deletedCourses()) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "courses" else { return nil }
        let id = parts[2]
        let action = parts.count == 4 ? parts[3] : nil
        let course = state.withLock { state in state.courses.first { $0.id == id } }
        if method == "POST", action == "undo-delete" { return undoCourseDelete(id) }
        if let course, course.deletedAt != nil {
            return failure(404, "course_not_found", "That course is not in the app.")
        }
        switch (method, action) {
        case ("GET", "delete-preview"):
            guard let course else { return failure(404, "course_not_found", "That course is not in the app.") }
            return (200, coursePreview(course, email: email))
        case ("DELETE", nil):
            guard let course else { return failure(404, "course_not_found", "That course is not in the app.") }
            return deleteCourse(course, confirm: query["confirm"], email: email)
        default:
            return nil
        }
    }

    /// What Home and the delete call it: a course by its code, a topic by its name.
    private static func name(_ course: FakeCourse) -> String {
        course.kind == "topic" ? course.title : course.code
    }

    private func coursePreview(_ course: FakeCourse, email: String) -> [String: Any] {
        let card = state.withLock { state in courseJSON(course, in: state) }
        let questions = card["questionCount"] as? Int ?? 0
        let name = Self.name(course)
        let folders = study.knows(course.id) ? study.folders(course.id) : []
        let semester = state.withLock { state in state.semesters.first { $0.id == course.semesterID } }
        return [
            "courseId": course.id, "kind": course.kind, "code": course.code, "title": course.title,
            "semester": semester.map { ["id": $0.id, "number": $0.number, "name": $0.name] as Any } ?? NSNull(),
            "folderCount": card["folderCount"] as? Int ?? 0, "examPageCount": study.courseExamsJSON(course.id).count,
            "setCount": folders.reduce(0) { $0 + $1.sets.count }, "questionCount": questions, "examQuestionCount": 0,
            "answeredCount": card["answeredCount"] as? Int ?? 0, "reviewCount": card["reviewCount"] as? Int ?? 0,
            "pastExamCount": folders.reduce(0) { $0 + study.pastExams(over: $1.id, courseID: course.id) },
            "message": "Delete \(questions == 0 ? name : "\(name) and its \(Wording.count(questions, "question"))")? You can bring it back for \(FakeDeletions.undoDays) days.",
            "refusal": json(courseInUse(course, email: email)), "confirm": Self.courseToken(course, questions: questions), "undoDays": FakeDeletions.undoDays,
        ]
    }

    /// The sentence refusing to delete it now: a job still working in it, or an exam in it still going.
    private func courseInUse(_ course: FakeCourse, email: String) -> String? {
        let name = Self.name(course)
        if twinJobs.isWorking(courseID: course.id, email: email) {
            return "QBank is still writing exam twins in \(name). Wait until they are filed, or cancel them, first."
        }
        if questionMaker.isWorking(courseID: course.id, email: email) {
            return "QBank is still making a set in \(name). Wait until it is filed, or cancel it, first."
        }
        return study.runningExams(courseID: course.id).isEmpty ? nil : "An exam in \(name) is still going. Finish or leave that exam first."
    }

    /// A short fingerprint of what deleting it takes, as the server's: 16 hex digits.
    private static func courseToken(_ course: FakeCourse, questions: Int) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ["course", course.id, course.kind, course.code, course.title, String(questions)].joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func deleteCourse(_ course: FakeCourse, confirm: String?, email: String) -> Reply {
        if let refusal = courseInUse(course, email: email) { return failure(409, "in_use", refusal) }
        let name = Self.name(course)
        guard let confirm else {
            return failure(409, "confirmation_required", "Look at what goes with \(name) and confirm it before deleting it.")
        }
        let questions = state.withLock { state in courseJSON(course, in: state)["questionCount"] as? Int ?? 0 }
        guard confirm == Self.courseToken(course, questions: questions) else {
            return failure(409, "deletion_changed", "\(name) changed since you were warned. Look again before deleting it.")
        }
        state.withLock { state in
            guard let index = state.courses.firstIndex(where: { $0.id == course.id }) else { return }
            state.courses[index].deletedAt = .now
        }
        return (204, [:])
    }

    private func undoCourseDelete(_ id: String) -> Reply {
        state.withLock { state in
            guard let index = state.courses.firstIndex(where: { $0.id == id }) else {
                return failure(404, "course_not_found", "That course is not in the app.")
            }
            let course = state.courses[index]
            guard course.deletedAt != nil else { return failure(409, "request_refused", "\(Self.name(course)) is not deleted.") }
            if let refusal = courseUndoRefusal(course, in: state) { return failure(409, refusal.code, refusal.message) }
            state.courses[index].deletedAt = nil
            return (200, courseJSON(state.courses[index], in: state))
        }
    }

    /// Why Undo cannot bring it back now: too late, or its code or name is taken now.
    private func courseUndoRefusal(_ course: FakeCourse, in state: State) -> (code: String, message: String)? {
        let name = Self.name(course)
        if let deletedAt = course.deletedAt, Date.now > Self.undoUntil(deletedAt) {
            return ("undo_expired", "\(name) was deleted more than \(FakeDeletions.undoDays) days ago, so it can't be brought back.")
        }
        let live = state.courses.filter { $0.id != course.id && $0.deletedAt == nil && $0.kind == course.kind }
        if course.kind == "topic" {
            guard let clash = live.first(where: { $0.title.lowercased() == course.title.lowercased() }) else { return nil }
            return ("request_refused", "You already have a topic named \(clash.title). Rename one of them, then bring this one back.")
        }
        guard let clash = live.first(where: { $0.semesterID == course.semesterID && $0.code.lowercased() == course.code.lowercased() }) else { return nil }
        let semester = state.semesters.first { $0.id == course.semesterID }?.name ?? "This semester"
        return ("request_refused", "\(semester) already has a course with the code \(clash.code). Rename one of them, then bring this one back.")
    }

    private static func undoUntil(_ deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(TimeInterval(FakeDeletions.undoDays) * 86_400)
    }

    /// Her courses and topics deleted in the last 30 days, newest first.
    private func deletedCourses() -> [String: Any] {
        state.withLock { state in
            let deleted = state.courses.compactMap { course in course.deletedAt.map { (course, $0) } }
                .filter { Date.now <= Self.undoUntil($0.1) }
                .sorted { $0.1 > $1.1 }
            return [
                "undoDays": FakeDeletions.undoDays,
                "courses": deleted.map { course, deletedAt -> [String: Any] in
                    let semester = state.semesters.first { $0.id == course.semesterID }
                    return [
                        "id": course.id, "kind": course.kind, "code": course.code, "title": course.title,
                        "semester": semester.map { ["id": $0.id, "number": $0.number, "name": $0.name] as Any } ?? NSNull(),
                        "questionCount": courseJSON(course, in: state)["questionCount"] as? Int ?? 0,
                        "deletedAt": QBankJSON.formatDate(deletedAt), "undoUntil": QBankJSON.formatDate(Self.undoUntil(deletedAt)),
                        "undoRefusal": json(courseUndoRefusal(course, in: state)?.message), "deletedByAgent": NSNull(),
                    ]
                },
            ]
        }
    }

    // MARK: Plumbing

    private func date(days: Int) -> String {
        QBankJSON.formatDate(now.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    /// A JSON value that is null when nil.
    private func json(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }

    // MARK: Deleting's library

    /// The invented exam banks' titles, by the start of their questions' ids.
    private static let examBanks = ["bank1": "Rights and Communication Exam", "bank3": "Depression and Anxiety Exam"]

    func deletionSet(_ id: String) -> (title: String, questionCount: Int, answeredCount: Int, versionCount: Int)? {
        guard let entry = summary(of: id) else { return nil }
        let answered = set(id)["answeredCount"] as? Int ?? 0
        return (entry.title, entry.questions, answered, entry.canRestore ? 2 : 1)
    }

    func examSetTitle(_ id: String) -> String {
        Self.examBanks[id] ?? summary(of: id)?.title ?? "Exam set"
    }

    func folderReply(_ folder: FakeStudy.Folder) -> [String: Any] {
        folderJSON(folder)
    }

    // MARK: Make questions' library

    func makerCourse(_ id: String) -> (code: String, title: String)? {
        state.withLock { state in state.courses.first { $0.id == id && $0.archivedAt == nil && $0.deletedAt == nil }.map { ($0.code, $0.title) } }
    }

    func makerFolderName(courseID: String, folderID: String) -> String? {
        study.folders(courseID).first { $0.id == folderID }?.name
    }

    func makerSetTitle(_ id: String) -> String? {
        summary(of: id)?.title
    }

    func fileMadeSet(
        courseID: String, folderID: String?, folderName: String, title: String, questionCount: Int, termCount: Int, examTwins: Int
    ) -> FakeQuestionMaker.Filed? {
        let named = folderID == nil && folderName != "Unsorted" ? folderName : nil
        guard case .success(let folder) = study.importFolder(courseID: courseID, folderID: folderID, folderName: named) else { return nil }
        let (setID, examID) = state.withLock { state -> (String, String?) in
            state.importCount += 1
            let setID = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            state.imported[setID] = ImportedEntry(
                courseID: courseID, title: title, kind: "practice", questionCount: questionCount, termCount: termCount,
                importedAt: .now, status: "imported", previous: nil
            )
            guard examTwins > 0 else { return (setID, nil) }
            state.importCount += 1
            let examID = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            state.imported[examID] = ImportedEntry(
                courseID: courseID, title: "\(title) exam", kind: "exam", questionCount: examTwins, termCount: 0,
                importedAt: .now, status: "imported", previous: nil
            )
            return (setID, examID)
        }
        study.file(set: setID, in: folder.id, replacing: nil, questionCount: questionCount)
        if let examID { study.file(bank: FakeStudy.ids("bank-\(examID)", examTwins), in: folder.id) }
        return FakeQuestionMaker.Filed(setID: setID, folderID: folder.id, folderName: folder.name, examPageID: folder.examPageID, examSetID: examID)
    }

    func fileTwinSet(courseID: String, folderID: String, title: String, questionCount: Int) -> (setID: String, examPageID: String?) {
        let setID = state.withLock { state -> String in
            state.importCount += 1
            let setID = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            state.imported[setID] = ImportedEntry(
                courseID: courseID, title: title, kind: "exam", questionCount: questionCount, termCount: 0,
                importedAt: .now, status: "imported", previous: nil
            )
            return setID
        }
        return (setID, study.folders(courseID).first { $0.id == folderID }?.examPageID)
    }
}

/// The parts of `POST /api/attempts` the fake server reads.
private nonisolated struct FakeSubmission: Decodable {
    let clientAttemptId: String
    let questionId: String
    let response: AnswerResponse
    let guessed: Bool
    let shuffle: Layout?
    let studySessionId: String?
}
#endif
