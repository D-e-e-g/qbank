import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The QBank API as the iPhone app uses it.
///
/// Sign-in stores the bearer token in the `SessionStore`; every later call sends it as
/// `Authorization: Bearer`. The client holds no API key and keeps no cookies.
public struct QBankClient: Sendable {
    public let configuration: APIConfiguration
    public let sessionStore: any SessionStore
    private let transport: any HTTPTransport

    public init(
        configuration: APIConfiguration = .production,
        transport: any HTTPTransport = URLSessionTransport(),
        sessionStore: any SessionStore
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sessionStore = sessionStore
    }

    // MARK: Sign-in and session

    /// `GET /health`.
    public func health() async throws(QBankError) -> Health {
        try await send(Request(.get, "/health", authenticated: false))
    }

    /// Makes a user account for an email the owner put on the sign-up list, signs it in, and stores
    /// the session, as a password sign-in does. Any other email, or one that already has an account,
    /// gets the same 403 `sign_up_refused`. Five refusals lock that email's sign-up for 15 minutes
    /// (`too_many_attempts`, 429, `retryAfterSeconds`), apart from its sign-in. A 502 `auth_failed`
    /// means the account was made but not signed in: she signs in instead.
    @discardableResult
    public func signUp(email: String, password: String) async throws(QBankError) -> SignedIn {
        let body = SignUpRequest(email: email, password: password)
        let signedIn: SignedIn = try await send(Request(.post, "/api/sign-up", body: body, authenticated: false))
        try store(signedIn)
        return signedIn
    }

    /// Signs in with email and password and stores the session.
    /// Five wrong passwords lock the address for 15 minutes (`too_many_attempts`, 429, `retryAfterSeconds`).
    @discardableResult
    public func signIn(email: String, password: String) async throws(QBankError) -> SignedIn {
        let body = PasswordSignInRequest(email: email, password: password)
        let signedIn: SignedIn = try await send(Request(.post, "/api/sign-in/password", body: body, authenticated: false))
        try store(signedIn)
        return signedIn
    }

    /// Checks the stored session with the server and refreshes the stored account.
    /// A 401 means the session ended; the stored one is left for the app to clear.
    public func session() async throws(QBankError) -> Session {
        let session: Session = try await send(Request(.get, "/api/session"))
        if let stored = try loadSession() {
            try save(StoredSession(token: stored.token, expiresAt: session.expiresAt, account: session.user))
        }
        return session
    }

    /// The user accounts the admin may look at, with the one chosen on the web. Refused for a user
    /// account.
    public func students() async throws(QBankError) -> StudentList {
        try await send(Request(.get, "/api/admin/students"))
    }

    /// The session stored on this device, without asking the server.
    public func storedSession() throws(QBankError) -> StoredSession? {
        try loadSession()
    }

    /// Ends this device's session on the server and forgets it here.
    /// The local session is cleared even when the server cannot be reached; the error still reports that.
    public func signOut() async throws(QBankError) {
        guard try loadSession() != nil else { return }
        var failure: QBankError?
        do {
            let _: StatusResponse = try await send(Request(.post, "/api/sign-out"))
        } catch {
            failure = error
        }
        do {
            try sessionStore.clear()
        } catch {
            throw .storage(error)
        }
        if let failure, !failure.needsSignIn { throw failure }
    }

    /// Ends every session of her account at once, on every device, this one included, and forgets
    /// it here. Agent keys are not sessions and keep working. Unlike `signOut`, nothing is forgotten
    /// until the server answers: a failure means the other devices may still be signed in, and it is
    /// thrown with this session kept. A 401 means this session had already ended; it is left for the
    /// app to clear, as `session()` leaves it. Any 2xx means they have all ended: the body is not
    /// read, and a stored session that cannot be cleared is left to end with its next 401.
    public func signOutEverywhere() async throws(QBankError) {
        _ = try await exchange(Request(.post, "/api/sign-out/everywhere"))
        try? sessionStore.clear()
    }

    /// Replaces her password, including a temporary one. Her other sessions end and this one
    /// gets a fresh token, which is stored.
    @discardableResult
    public func changePassword(current: String, new: String) async throws(QBankError) -> SignedIn {
        let body = ChangePasswordRequest(currentPassword: current, newPassword: new)
        let signedIn: SignedIn = try await send(Request(.post, "/api/account/password", body: body))
        try store(signedIn)
        return signedIn
    }

    /// Deletes the signed-in user account and everything it has, for good: its semesters, courses
    /// and study topics with everything in them, its answers, progress, Review and past exams, its
    /// jobs, passkeys and agent keys. Nothing goes to Recently deleted and there is no Undo. The
    /// request names no account: it is always the one this session belongs to, checked with her
    /// current password. Every session of the account ends, on every device, and this one is
    /// forgotten here. Any 2xx means it is gone: the body is not read, and a stored session that
    /// cannot be cleared is left to end with its next 401.
    ///
    /// Refusals delete nothing: a wrong password is 401 `invalid_credentials` and counts toward the
    /// sign-in lock (`too_many_attempts`, 429, `retryAfterSeconds`); a temporary password is 403
    /// `must_change_password`; the admin is 403 `admin_cannot_delete_account`; and a Make questions
    /// or exam twins job still running in one of her courses is 409 `in_use`, whose message names it.
    public func deleteAccount(password: String) async throws(QBankError) {
        _ = try await exchange(Request(.delete, "/api/me", body: DeleteAccountRequest(password: password)))
        try? sessionStore.clear()
    }

    // MARK: Courses

    /// Home: her semesters with their courses, and her study topics.
    public func catalog() async throws(QBankError) -> Catalog {
        try await send(Request(.get, "/api/semesters"))
    }

    /// A course or topic, its folders and exam pages, and its practice sets.
    public func course(id: String) async throws(QBankError) -> CourseDetail {
        try await send(Request(.get, "/api/courses/\(id)"))
    }

    /// The course's terms, newest definition first when a term is defined twice.
    public func terms(courseID: String) async throws(QBankError) -> [Term] {
        let response: TermsResponse = try await send(Request(.get, "/api/courses/\(courseID)/terms"))
        return response.terms
    }

    /// The questions of a practice set, in the order she practices them.
    public func practiceSet(id: String) async throws(QBankError) -> PracticeSet {
        try await send(Request(.get, "/api/practice-sets/\(id)"))
    }

    /// Brings back the previous version of a replaced set and returns the version that is current
    /// now. Her answers to either version stay. Restoring again swaps back.
    @discardableResult
    public func restorePracticeSet(id: String) async throws(QBankError) -> PracticeSetSummary {
        try await send(Request(.post, "/api/practice-sets/\(id)/restore"))
    }

    /// Ends the sitting she would continue, so the set opens at question 1. Every answer stays saved
    /// and still counts. Asking with nothing to end changes nothing.
    ///
    /// - Returns: Whether there was a sitting to end.
    @discardableResult
    public func startPracticeSetOver(id: String) async throws(QBankError) -> Bool {
        let result: StartOverResult = try await send(Request(.post, "/api/practice-sets/\(id)/start-over"))
        return result.ended
    }

    // MARK: Import

    /// Checks a question file without importing it: its counts and formats, or the errors that
    /// block it, in the importer's words. Nothing is written.
    public func checkImport(source: String) async throws(QBankError) -> ImportReport {
        try await send(Request(.post, "/api/imports/check", body: ImportSourceRequest(source: source)))
    }

    /// Imports a question file into a course and folder. When the course already has a set of this
    /// name, nothing is written and the answer is `.conflict`: she chooses, and the same request goes
    /// again with `.replace` or `.separate`. A file the importer refuses is a 400 `invalid_import`
    /// whose message is its first error.
    public func importSet(_ request: ImportRequest) async throws(QBankError) -> ImportOutcome {
        let call = Request(.post, "/api/imports", body: ImportSetRequest(request: request))
        let (data, status) = try await exchange(call, accepting: [409])
        if status == 409 {
            return .conflict(try decode(ImportConflict.self, from: data, status: status, for: call))
        }
        return .imported(try decode(ImportedSet.self, from: data, status: status, for: call))
    }

    // MARK: Making questions

    /// Whether she may start a set now, why not in the server's words, and the choices: the levels
    /// and their counts, and how much material one set takes.
    public func questionMakerStatus() async throws(QBankError) -> QuestionMakerStatus {
        try await send(Request(.get, "/api/question-maker"))
    }

    /// Her recent sets, newest first: those still going and the last few finished. An account the
    /// server does not allow is refused with `not_allowed`, and a server without its Claude key
    /// with `not_set_up`, each with a sentence to show as it is.
    public func questionJobs() async throws(QBankError) -> [QuestionJob] {
        let list: QuestionJobList = try await send(Request(.get, "/api/question-jobs"))
        return list.jobs
    }

    /// Starts a set from her material and answers at once; QBank works on it in the background.
    /// Past the daily limit it is refused with `daily_limit`, in the server's words.
    public func startQuestionJob(_ job: NewQuestionJob) async throws(QBankError) -> QuestionJob {
        try await send(Request(.post, "/api/question-jobs", body: NewQuestionJobBody(job: job)))
    }

    /// A set being made, as far as it got.
    public func questionJob(id: String) async throws(QBankError) -> QuestionJob {
        try await send(Request(.get, "/api/question-jobs/\(id)"))
    }

    /// The samples she checks, while the set waits for her.
    public func questionSamples(jobID: String) async throws(QBankError) -> QuestionSamples {
        try await send(Request(.get, "/api/question-jobs/\(jobID)/samples"))
    }

    /// The samples look right: QBank writes the rest the same way, with what she said about them.
    public func acceptSamples(jobID: String, words: String?) async throws(QBankError) -> QuestionJob {
        try await send(Request(.post, "/api/question-jobs/\(jobID)/samples/accept", body: AcceptSamplesBody(words: words)))
    }

    /// Writes the samples again from her notes on single samples, on all of them, or both.
    public func reviseSamples(jobID: String, changes: [SampleChange], note: String? = nil) async throws(QBankError) -> QuestionJob {
        try await send(Request(.post, "/api/question-jobs/\(jobID)/samples/revise", body: ReviseSamplesBody(changes: changes, note: note)))
    }

    /// The questions copied from her photos, while the set waits for her check.
    public func questionCopies(jobID: String) async throws(QBankError) -> QuestionCopies {
        try await send(Request(.get, "/api/question-jobs/\(jobID)/copies"))
    }

    /// Keeps the copies she checked, in her order, with her fixes; the rest are left out.
    public func acceptCopies(jobID: String, keep: [KeptCopy]) async throws(QBankError) -> QuestionJob {
        try await send(Request(.post, "/api/question-jobs/\(jobID)/copies/accept", body: AcceptCopiesBody(keep)))
    }

    /// The finished set, its exam twins, and the blind check.
    public func questionResult(jobID: String) async throws(QBankError) -> QuestionResult {
        try await send(Request(.get, "/api/question-jobs/\(jobID)/result"))
    }

    /// Stops a set that is still going. Nothing more is written or filed, and her material is deleted.
    public func cancelQuestionJob(id: String) async throws(QBankError) -> QuestionJob {
        try await send(Request(.post, "/api/question-jobs/\(id)/cancel"))
    }

    // MARK: Exam twins

    /// Her recent twin jobs, newest first, over every course. Refused like `questionJobs()` for an
    /// account the server does not allow and on a server without its Claude key.
    public func twinJobs() async throws(QBankError) -> [TwinJob] {
        let list: TwinJobList = try await send(Request(.get, "/api/twin-jobs"))
        return list.jobs
    }

    /// Starts exam twins of the questions in these folders and pool, and answers at once; QBank
    /// works on them in the background. Refused with a sentence when there is nothing to twin, too
    /// much at once, a folder another twin job is still twinning, or past the daily limit.
    public func startTwinJob(_ job: NewTwinJob) async throws(QBankError) -> TwinJob {
        try await send(Request(.post, "/api/twin-jobs", body: job))
    }

    /// A twin job, as far as it got.
    public func twinJob(id: String) async throws(QBankError) -> TwinJob {
        try await send(Request(.get, "/api/twin-jobs/\(id)"))
    }

    /// Stops a twin job that is still going. Nothing more is written or filed; sets already filed stay.
    public func cancelTwinJob(id: String) async throws(QBankError) -> TwinJob {
        try await send(Request(.post, "/api/twin-jobs/\(id)/cancel"))
    }

    // MARK: Folders

    /// Adds an empty folder to the course, on no exam page, at the end of that list. A name the
    /// list already has, in any case, is refused with 409 in her words.
    @discardableResult
    public func createFolder(courseID: String, name: String) async throws(QBankError) -> Folder {
        try await send(Request(.post, "/api/courses/\(courseID)/folders", body: FolderNameRequest(name: name)))
    }

    /// Renames a folder. Only the name changes: its sets, their progress, its exam page and her
    /// past exams stay with it. A name its list already has is refused with 409 in her words.
    @discardableResult
    public func renameFolder(id: String, name: String) async throws(QBankError) -> Folder {
        try await send(Request(.patch, "/api/folders/\(id)", body: FolderNameRequest(name: name)))
    }

    /// Puts a folder on an exam page, at the end of its folders, or with `examPageID` nil takes it
    /// off its page, to the end of the course's Folders list. Its sets and progress stay in it. A
    /// name the new list already has is refused with 409 in her words.
    @discardableResult
    public func placeFolder(id: String, onExamPage examPageID: String?) async throws(QBankError) -> Folder {
        try await send(Request(.patch, "/api/folders/\(id)", body: FolderPageRequest(examPageId: examPageID)))
    }

    /// Moves a set, with every version of it, into another folder of its course. Her answers and
    /// progress move with it. Returns the folder it is in now.
    @discardableResult
    public func moveSet(id: String, toFolder folderID: String) async throws(QBankError) -> Folder {
        try await send(Request(.post, "/api/practice-sets/\(id)/move", body: MoveSetRequest(folderId: folderID, newFolderName: nil)))
    }

    /// Moves a set into a new folder by that name, made at the end of the course's Folders list.
    @discardableResult
    public func moveSet(id: String, toNewFolder name: String) async throws(QBankError) -> Folder {
        try await send(Request(.post, "/api/practice-sets/\(id)/move", body: MoveSetRequest(folderId: nil, newFolderName: name)))
    }

    /// Saves her order of one list: an exam page's folders, or with `examPageID` nil, the folders on
    /// no exam page. A list that does not name exactly the folders it holds is refused with 409.
    /// Returns the list's folders in the new order.
    @discardableResult
    public func setFolderOrder(courseID: String, examPageID: String?, folderIDs: [String]) async throws(QBankError) -> [Folder] {
        let body = FolderOrderRequest(examPageId: examPageID, folderIds: folderIDs)
        let list: FolderList = try await send(Request(.put, "/api/courses/\(courseID)/folder-order", body: body))
        return list.folders
    }

    // MARK: Deleting and Undo

    /// What deleting a set (a practice set, or an exam set from `Folder.examSets`) takes with it,
    /// with the warning to show her and the `confirm` that deletes exactly that.
    public func practiceSetDeletion(id: String) async throws(QBankError) -> SetDeletion {
        try await send(Request(.get, "/api/practice-sets/\(id)/delete-preview"))
    }

    /// Deletes a set and every version of it, as its preview named. Refused with 409
    /// `deletion_changed` when what goes changed since the preview, and `in_use` while a job or an
    /// exam in progress uses it; nothing is deleted then.
    public func deletePracticeSet(id: String, confirm: String) async throws(QBankError) {
        _ = try await exchange(Request(.delete, "/api/practice-sets/\(id)", query: [("confirm", confirm)]))
    }

    /// Brings back a set she deleted on its own, every version as it was, within 30 days. Returns
    /// the folder it is in, with it back.
    @discardableResult
    public func undoDeletePracticeSet(id: String) async throws(QBankError) -> Folder {
        try await send(Request(.post, "/api/practice-sets/\(id)/undo-delete"))
    }

    /// What deleting a folder takes with it: every set in it, by title, their questions and her
    /// answers, and its exam page.
    public func folderDeletion(id: String) async throws(QBankError) -> FolderDeletion {
        try await send(Request(.get, "/api/folders/\(id)/delete-preview"))
    }

    /// Deletes a folder and every set in it, as its preview named; it comes off its exam page. Her
    /// past exams over it stay. The same refusals as `deletePracticeSet`.
    public func deleteFolder(id: String, confirm: String) async throws(QBankError) {
        _ = try await exchange(Request(.delete, "/api/folders/\(id)", query: [("confirm", confirm)]))
    }

    /// Brings back a folder she deleted and the sets that went with it, within 30 days: on its exam
    /// page if that is still there, else in the Folders list. Refused with 409 when its list has a
    /// folder of its name now.
    @discardableResult
    public func undoDeleteFolder(id: String) async throws(QBankError) -> Folder {
        try await send(Request(.post, "/api/folders/\(id)/undo-delete"))
    }

    /// What deleting one of her past exams changes: her answers on it, and her Review list and Wrong
    /// questions. `refusal` is set while the exam is still going.
    public func examDeletion(id: String) async throws(QBankError) -> ExamDeletion {
        try await send(Request(.get, "/api/exams/\(id)/delete-preview"))
    }

    /// Deletes one of her ended exams, as its preview described: its answers stop counting toward
    /// her progress. An exam still going is refused with 409 `exam_in_progress`.
    public func deleteExam(id: String, confirm: String) async throws(QBankError) {
        _ = try await exchange(Request(.delete, "/api/exams/\(id)", query: [("confirm", confirm)]))
    }

    /// Brings back her past exam within 30 days, with its answers counting again. Returns it as
    /// Exam setup lists it.
    @discardableResult
    public func undoDeleteExam(id: String) async throws(QBankError) -> ExamSummary {
        try await send(Request(.post, "/api/exams/\(id)/undo-delete"))
    }

    /// The course's exam pages, folders and sets, and her past exams, deleted in the last 30 days,
    /// newest first.
    public func recentlyDeleted(courseID: String) async throws(QBankError) -> RecentlyDeleted {
        try await send(Request(.get, "/api/courses/\(courseID)/deleted"))
    }

    /// What deleting a course or study topic takes with it, and the one question to ask her.
    /// `refusal` is set while a job or an exam in progress still works in it.
    public func courseDeletion(id: String) async throws(QBankError) -> CourseDeletion {
        try await send(Request(.get, "/api/courses/\(id)/delete-preview"))
    }

    /// Deletes a course or study topic with everything in it, as its preview named. It leaves Home,
    /// and its code, or a topic's name, is free again meanwhile. Refused with 409 `in_use` while a
    /// job or an exam in progress works in it, and `deletion_changed` when what goes changed since
    /// the preview; nothing is deleted then. The admin is refused with 403.
    public func deleteCourse(id: String, confirm: String) async throws(QBankError) {
        _ = try await exchange(Request(.delete, "/api/courses/\(id)", query: [("confirm", confirm)]))
    }

    /// Brings back a course or study topic she deleted, whole, within 30 days, in its semester or her
    /// topics as before. Refused with 409 when its semester has a course of its code now, or she has
    /// a topic of its name. Returns its card.
    @discardableResult
    public func undoDeleteCourse(id: String) async throws(QBankError) -> CourseSummary {
        try await send(Request(.post, "/api/courses/\(id)/undo-delete"))
    }

    /// Her courses and study topics deleted in the last 30 days, newest first.
    public func recentlyDeletedCourses() async throws(QBankError) -> RecentlyDeletedCourses {
        try await send(Request(.get, "/api/deleted-courses"))
    }

    // MARK: Exam pages

    /// Adds an exam page, such as "Exam 1", with some of the course's folders on it in that order,
    /// after its other pages. A folder on another page is refused with 409, naming it ("Week 2 is
    /// in Exam 1."), as is a name the course already uses.
    /// A topic's study page can take a primer link, an http or https address the server checks.
    public func createCourseExam(courseID: String, name: String, folderIDs: [String], link: PrimerLink = .unchanged) async throws(QBankError) -> CourseExam {
        try await send(Request(.post, "/api/courses/\(courseID)/course-exams", body: CourseExamRequest(name: name, folderIds: folderIDs, link: link)))
    }

    /// Renames an exam page and replaces its folders, in the order sent, with the same refusals as
    /// `createCourseExam`. A folder taken off goes to the end of the course's Folders list. The
    /// primer link stays as it is unless `link` says otherwise, and the badge unless `badge` is
    /// given: `.some(nil)` takes it off.
    public func updateCourseExam(
        id: String, name: String, folderIDs: [String], link: PrimerLink = .unchanged, badge: PageBadge?? = nil
    ) async throws(QBankError) -> CourseExam {
        let body = CourseExamRequest(name: name, folderIds: folderIDs, link: link, badge: badge)
        return try await send(Request(.put, "/api/course-exams/\(id)", body: body))
    }

    /// What deleting an exam page changes: the page alone goes, and its folders stay, named, with
    /// their sets. A page she deleted is 404.
    public func courseExamDeletion(id: String) async throws(QBankError) -> ExamPageDeletion {
        try await send(Request(.get, "/api/course-exams/\(id)/delete-preview"))
    }

    /// Deletes an exam page, as its preview named: the page alone. Its folders show on no page, at
    /// the end of the course's Folders list, with their sets and her progress, and her past exams
    /// stay in Exam setup. Refused with 409 `deletion_changed` when the page or its folders changed
    /// since the preview, and with 409 while one of its folders has the name of a folder already in
    /// the Folders list; nothing is deleted then.
    public func deleteCourseExam(id: String, confirm: String) async throws(QBankError) {
        _ = try await exchange(Request(.delete, "/api/course-exams/\(id)", query: [("confirm", confirm)]))
    }

    /// Brings back an exam page she deleted, within 30 days, in its place with the folders still on
    /// no other page back on it. Refused while another page has its name, and with `undo_expired`
    /// after 30 days. Returns the page.
    public func undoDeleteCourseExam(id: String) async throws(QBankError) -> CourseExam {
        try await send(Request(.post, "/api/course-exams/\(id)/undo-delete"))
    }

    // MARK: Semesters and courses

    /// Adds semester `number` (1, 2, or 3), named "Semester N". A number that exists is
    /// refused with 409 `request_refused`.
    public func addSemester(number: Int) async throws(QBankError) -> Semester {
        try await send(Request(.post, "/api/semesters", body: AddSemesterRequest(number: number)))
    }

    /// Renames a semester and sets its dates, calendar dates such as `2026-09-01`. A nil date clears it.
    public func updateSemester(id: String, name: String, startsOn: String?, endsOn: String?) async throws(QBankError) -> Semester {
        let body = UpdateSemesterRequest(name: name, startsOn: startsOn, endsOn: endsOn)
        return try await send(Request(.patch, "/api/semesters/\(id)", body: body))
    }

    /// Archives a semester by hand, or brings it back. Nothing archives one on its own.
    public func setSemesterArchived(id: String, _ archived: Bool) async throws(QBankError) -> Semester {
        try await send(Request(.patch, "/api/semesters/\(id)", body: ArchiveSemesterRequest(archived: archived)))
    }

    /// Adds an empty course to a semester. A code the semester already has, in any case, is
    /// refused with 409 `request_refused`.
    public func addCourse(semesterID: String, code: String, title: String) async throws(QBankError) -> CourseSummary {
        try await send(Request(.post, "/api/courses", body: AddCourseRequest(semesterId: semesterID, code: code, title: title)))
    }

    /// Renames a course, or moves it to another semester. Her answers stay with it.
    public func updateCourse(id: String, code: String, title: String, semesterID: String) async throws(QBankError) -> CourseSummary {
        let body = UpdateCourseRequest(code: code, title: title, semesterId: semesterID, archived: nil)
        return try await send(Request(.patch, "/api/courses/\(id)", body: body))
    }

    /// Archives a course or topic, which moves to Home's Archived group, or brings it back. Her
    /// answers stay.
    public func setCourseArchived(id: String, _ archived: Bool) async throws(QBankError) -> CourseSummary {
        let body = UpdateCourseRequest(code: nil, title: nil, semesterId: nil, archived: archived)
        return try await send(Request(.patch, "/api/courses/\(id)", body: body))
    }

    // MARK: Study topics

    /// Makes a study topic of hers, after her other topics: a course with no semester, called by
    /// its name. A name another of her topics has, in any case, is refused with 409.
    public func createTopic(title: String) async throws(QBankError) -> CourseSummary {
        try await send(Request(.post, "/api/topics", body: AddTopicRequest(title: title)))
    }

    /// Renames a topic. Its folders, pages, sets and her answers stay with it.
    public func renameTopic(id: String, title: String) async throws(QBankError) -> CourseSummary {
        let body = UpdateCourseRequest(code: nil, title: title, semesterId: nil, archived: nil)
        return try await send(Request(.patch, "/api/courses/\(id)", body: body))
    }

    /// Puts her topics in this order. The list names every topic of hers, archived ones included,
    /// once each, or it is refused with 409, so a stale screen cannot drop one.
    public func setTopicOrder(_ topicIDs: [String]) async throws(QBankError) -> [CourseSummary] {
        let response: TopicsResponse = try await send(Request(.put, "/api/topic-order", body: TopicOrderRequest(topicIds: topicIDs)))
        return response.topics
    }

    // MARK: Answers

    /// Sends one answer. The server scores it and saves her progress. Sending the same
    /// `clientAttemptID` again returns the saved attempt with `replayed` set and counts nothing twice.
    public func recordAttempt(_ attempt: AttemptSubmission) async throws(QBankError) -> SavedAttempt {
        try await send(Request(.post, "/api/attempts", body: attempt))
    }

    // MARK: Review

    public func review(courseID: String, filter: ReviewFilter = .all) async throws(QBankError) -> ReviewList {
        try await send(Request(.get, "/api/courses/\(courseID)/review", query: filter == .all ? [] : [("filter", filter.rawValue)]))
    }

    /// The Review questions for the runner, in a new shuffled order each time, or only `questionID`.
    public func reviewPractice(courseID: String, filter: ReviewFilter = .all, questionID: String? = nil) async throws(QBankError) -> PracticeSet {
        var query: [(String, String)] = []
        if filter != .all { query.append(("filter", filter.rawValue)) }
        if let questionID { query.append(("question", questionID)) }
        return try await send(Request(.get, "/api/courses/\(courseID)/review/practice", query: query))
    }

    /// Empties the course's Review list. Answers and scores stay. Returns how many questions left it.
    /// The app asks her first; `confirmed: false` returns 400 `confirmation_required` with the question to ask.
    @discardableResult
    public func clearReview(courseID: String, confirmed: Bool = true) async throws(QBankError) -> Int {
        let response: ClearReviewResponse = try await send(
            Request(.post, "/api/courses/\(courseID)/review/clear", body: ClearReviewRequest(confirmed: confirmed))
        )
        return response.cleared
    }

    // MARK: Exams

    /// The folder picker with per-folder wrong counts, her running exam, her ended exams, and the
    /// server's exam rules. With `folderIDs`, its `preview` is the exam that starting over them from
    /// `pool` would give.
    public func examSetup(courseID: String, folderIDs: [String] = [], pool: ExamPool = .all) async throws(QBankError) -> ExamSetup {
        let query = folderIDs.isEmpty ? [] : folderIDs.map { ("folderIds", $0) } + [("pool", pool.rawValue)]
        return try await send(Request(.get, "/api/courses/\(courseID)/exams", query: query))
    }

    /// Starts an exam over the ticked folders, sized and timed by the server's rules and drawn from
    /// their sets in proportion to each folder's size. With `.wrong`, only the questions she last
    /// answered not fully right; a ticked folder with none is refused with 400 `no_wrong_questions`.
    ///
    /// `replaces` is the running exam she agreed to end, or nil when the app knows of none. When
    /// another exam is running, nothing starts or ends, and the answer is `.examInProgress` with it.
    public func startExam(courseID: String, folderIDs: [String], pool: ExamPool = .all, replaces: String?) async throws(QBankError) -> ExamStart {
        try await startExam(Request(.post, "/api/courses/\(courseID)/exams", body: StartExamRequest(folderIds: folderIDs, pool: pool, replaces: replaces)))
    }

    /// Starts the exam a finished twin job names, on its twins, sending its body as the server
    /// wrote it with `replaces` added, as with `startExam(courseID:folderIDs:pool:replaces:)`.
    public func startExam(courseID: String, on twins: TwinJob.Exam, replaces: String?) async throws(QBankError) -> ExamStart {
        try await startExam(Request(.post, "/api/courses/\(courseID)/exams", body: twins.replacing(replaces)))
    }

    private func startExam(_ call: Request) async throws(QBankError) -> ExamStart {
        let (data, status) = try await exchange(call, accepting: [409])
        guard status == 409 else {
            return .started(try decode(Exam.self, from: data, status: status, for: call))
        }
        if let refusal = try? QBankJSON.decoder.decode(ExamInProgressRefusal.self, from: data), refusal.error == ServerError.Code.examInProgress.rawValue {
            return .examInProgress(refusal.inProgress)
        }
        // Any other conflict is a refusal like every route's.
        guard let body = try? QBankJSON.decoder.decode(ErrorBody.self, from: data) else {
            throw .unexpectedResponse(status: status, detail: String(decoding: data.prefix(200), as: UTF8.self))
        }
        throw .server(ServerError(status: status, code: .init(rawValue: body.error), message: body.message, retryAfterSeconds: body.retryAfterSeconds))
    }

    /// One exam. An exam whose time ran out is ended first.
    public func exam(id: String) async throws(QBankError) -> Exam {
        try await send(Request(.get, "/api/exams/\(id)"))
    }

    /// Ends the exam and scores it. Ending an ended exam returns it unchanged.
    public func finishExam(id: String, reason: ExamEndReason) async throws(QBankError) -> Exam {
        try await send(Request(.post, "/api/exams/\(id)/finish", body: FinishExamRequest(reason: reason)))
    }

    // MARK: Settings

    /// The course she used last, or nil.
    public func studyPlace() async throws(QBankError) -> String? {
        let place: StudyPlaceBody = try await send(Request(.get, "/api/me/place"))
        return place.courseId
    }

    /// Remembers the course she just opened.
    public func setStudyPlace(courseID: String) async throws(QBankError) {
        let _: StudyPlaceBody = try await send(Request(.put, "/api/me/place", body: StudyPlaceBody(courseId: courseID)))
    }

    /// Picks the account's color scheme on every device, and keeps the account it returns as the
    /// one this device opens with.
    @discardableResult
    public func setPalette(_ palette: Account.Palette) async throws(QBankError) -> Account {
        let account: Account = try await send(Request(.put, "/api/me/palette", body: PaletteUpdate(palette: palette)))
        if let stored = try loadSession() {
            try save(StoredSession(token: stored.token, expiresAt: stored.expiresAt, account: account))
        }
        return account
    }

    /// Her progress as one JSON file, for the share sheet.
    public func exportProgress() async throws(QBankError) -> Data {
        try await sendForData(Request(.get, "/api/me/export"))
    }

    // MARK: Agents

    /// The agent waiting under the code her agent shows her, before she answers: its name and what
    /// its key would be able to do. The server takes the code in any case, with or without its dash.
    ///
    /// No agent waiting under it (mistyped, answered already, or past its 10 minutes) is 404
    /// `pairing_not_found`. Codes count like passwords: five that match nothing lock her answers for
    /// 15 minutes (`too_many_attempts`, 429, `retryAfterSeconds`), the right code included.
    public func agentPairing(code: String) async throws(QBankError) -> AgentPairing {
        try await send(Request(.post, "/api/agent-pairings/lookup", body: AgentPairingCodeRequest(userCode: code)))
    }

    /// Approves the agent waiting under the code, for this account. The agent picks its key up on its
    /// next poll, and only then does `agentKeys()` list it. Refused as `agentPairing(code:)` is.
    @discardableResult
    public func approveAgentPairing(code: String) async throws(QBankError) -> AgentPairing {
        try await send(Request(.post, "/api/agent-pairings/approve", body: AgentPairingCodeRequest(userCode: code)))
    }

    /// Denies the agent waiting under the code: no key is made. Refused as `agentPairing(code:)` is.
    @discardableResult
    public func denyAgentPairing(code: String) async throws(QBankError) -> AgentPairing {
        try await send(Request(.post, "/api/agent-pairings/deny", body: AgentPairingCodeRequest(userCode: code)))
    }

    /// The account's agent keys, newest first, revoked ones included. Never a key itself.
    public func agentKeys() async throws(QBankError) -> [AgentKey] {
        let response: AgentKeysResponse = try await send(Request(.get, "/api/agent-keys"))
        return response.keys
    }

    /// Revokes one of her agent keys: it stops working at once and for good, and stays listed. What it
    /// imported keeps its name. Revoking a revoked key changes nothing. A key she does not have is 404
    /// `agent_key_not_found`.
    @discardableResult
    public func revokeAgentKey(id: String) async throws(QBankError) -> AgentKey {
        try await send(Request(.post, "/api/agent-keys/\(id)/revoke"))
    }

    // MARK: Plumbing

    private func store(_ signedIn: SignedIn) throws(QBankError) {
        try save(StoredSession(token: signedIn.token, expiresAt: signedIn.expiresAt, account: signedIn.user))
    }

    private func loadSession() throws(QBankError) -> StoredSession? {
        do {
            return try sessionStore.load()
        } catch {
            throw .storage(error)
        }
    }

    private func save(_ session: StoredSession) throws(QBankError) {
        do {
            try sessionStore.save(session)
        } catch {
            throw .storage(error)
        }
    }

    private func send<Response: Decodable>(_ request: Request) async throws(QBankError) -> Response {
        let (data, status) = try await exchange(request)
        return try decode(Response.self, from: data, status: status, for: request)
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data, status: Int, for request: Request) throws(QBankError) -> Response {
        do {
            return try QBankJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw .unexpectedResponse(status: status, detail: "The answer to \(request.method.rawValue) \(request.path) does not match \(Response.self): \(error)")
        }
    }

    private func sendForData(_ request: Request) async throws(QBankError) -> Data {
        try await exchange(request).data
    }

    /// Sends the request and returns the answer's body and status. A status outside 2xx is thrown as
    /// the server's error, unless the route answers it with its own body (`accepting`).
    private func exchange(_ request: Request, accepting: Set<Int> = []) async throws(QBankError) -> (data: Data, status: Int) {
        var token: String?
        if request.authenticated {
            guard let session = try loadSession() else { throw .notSignedIn }
            token = session.token
        }
        let urlRequest = try request.urlRequest(configuration: configuration, token: token)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as URLError {
            throw error.code == .cancelled ? .cancelled : .transport(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .transport(.unknown)
        }
        let status = response.statusCode
        guard (200..<300).contains(status) || accepting.contains(status) else {
            throw Self.failure(status: status, data: data, response: response)
        }
        return (data, status)
    }

    static func failure(status: Int, data: Data, response: HTTPURLResponse) -> QBankError {
        guard let body = try? QBankJSON.decoder.decode(ErrorBody.self, from: data) else {
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            return .unexpectedResponse(status: status, detail: text.isEmpty ? "No body" : text)
        }
        let retryAfter = body.retryAfterSeconds ?? response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        return .server(ServerError(status: status, code: .init(rawValue: body.error), message: body.message, retryAfterSeconds: retryAfter))
    }
}

/// The body of `POST /api/practice-sets/{id}/start-over`'s answer: whether a sitting was open to end.
private struct StartOverResult: Decodable {
    let ended: Bool
}

/// The body of `PUT /api/courses/{id}/folder-order`'s answer: one list's folders in the new order.
private struct FolderList: Decodable {
    let folders: [Folder]
}

/// One API call before it becomes a URLRequest.
struct Request {
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    let method: Method
    let path: String
    let query: [(String, String)]
    let body: (any Encodable & Sendable)?
    let authenticated: Bool

    init(
        _ method: Method,
        _ path: String,
        query: [(String, String)] = [],
        body: (any Encodable & Sendable)? = nil,
        authenticated: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.authenticated = authenticated
    }

    func urlRequest(configuration: APIConfiguration, token: String?) throws(QBankError) -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw .invalidRequest("Bad base URL \(configuration.baseURL)")
        }
        // Path parameters are ids from the server; percent-encode them anyway.
        let base = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else {
            throw .invalidRequest("Bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            do {
                request.httpBody = try QBankJSON.encoder.encode(body)
            } catch {
                throw .invalidRequest("Cannot encode the request body: \(error)")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
