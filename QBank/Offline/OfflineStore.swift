import Foundation
import Observation
import QBankKit

/// A value a screen loaded, and whether it is the copy saved on the phone.
struct Loaded<Value> {
    let value: Value
    /// When the copy on screen was saved on the phone, or nil when it came from the server just now.
    let savedAt: Date?
}

/// What happened to an answer she checked.
enum Delivery: Equatable {
    /// The server scored and saved it.
    case sent(SavedAttempt)
    /// It waits on the phone and is sent when QBank can be reached. `reason` is why it could not go now.
    case waiting(reason: QBankError)
    /// QBank took it but its reply could not be read, so the phone's score stands.
    case accepted
}

/// Waiting answers from one set, as Saved for offline lists them: "3 answers", "Rights, Law, and
/// Ethics · answered 8:02 to 8:06".
nonisolated struct WaitingGroup: Identifiable, Equatable {
    /// The set's id, or the course's when the set is not saved on the phone.
    let id: String
    let title: String
    let count: Int
    let firstAnsweredAt: Date
    let lastAnsweredAt: Date
}

/// A course or topic saved on the phone, as Saved for offline lists it.
nonisolated struct SavedCourse: Identifiable, Equatable, CourseNaming {
    let id: String
    let kind: CourseKind
    let code: String
    let title: String
    /// The course's practice questions.
    let questionCount: Int
    /// The questions of its sets saved on the phone.
    let savedQuestionCount: Int
    /// Whether every one of its sets is saved.
    let isComplete: Bool
    let savedAt: Date
}

/// What this phone keeps for one signed-in account, so she can study without signal: the courses,
/// sets and questions she has loaded, and her answers until QBank has them.
///
/// Screens read from the server when they can and keep a copy; without a connection they show the
/// copy saved last. Practice answers go through QBankKit's `AttemptQueue`: saved on the phone first,
/// sent oldest first, and sent again until the server has them, which is safe because every answer
/// carries its own `clientAttemptId`. Exams never use this: they start, take answers and end on
/// the server, so they need a connection.
@Observable
final class OfflineStore {
    let accountID: String
    /// Answers on this phone that QBank does not have yet, oldest first.
    private(set) var waiting: [PendingAttempt]
    private(set) var isSending = false
    /// Answers QBank refused while they were being sent, so they were not saved. Kept until she
    /// dismisses them or the app closes.
    private(set) var notSaved: [RefusedAttempt] = []
    /// Goes up each time a send delivers answers, so screens reload the server's counts.
    private(set) var deliveries = 0
    /// Goes up each time the saved courses change.
    private(set) var savedRevision = 0
    private(set) var isSavingCourses = false
    /// Why the answers waiting on this phone could not be read at launch, said on Home, in the
    /// runner, and in Saved for offline.
    let problem: String?
    /// False when the phone cannot keep answers in a file: they wait only until the app closes.
    let keepsAnswers: Bool

    private let client: QBankClient
    private let connection: Connection
    private let cache: any ContentCache
    private let queue: AttemptQueue
    private let now: @Sendable () -> Date
    private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var sending: Task<FlushReport, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = OfflineStore.firstRetryDelay
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var coursesSavedAt: Date?
    /// Set once she signs out or her session ends: nothing more is sent or saved.
    @ObservationIgnored private var isClosed = false

    static let firstRetryDelay = Duration.seconds(5)
    static let longestRetryDelay = Duration.seconds(120)
    /// How long Home waits before saving every course again, unless she pulls to refresh.
    static let saveInterval: TimeInterval = 10 * 60

    init(
        accountID: String,
        client: QBankClient,
        connection: Connection,
        storage: PhoneStorage.Account,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.accountID = accountID
        self.client = client
        self.connection = connection
        self.cache = storage.cache
        self.now = now
        self.sleep = sleep
        let queue: AttemptQueue
        if let opened = try? AttemptQueue(store: storage.pending, sender: client, now: now) {
            queue = opened
            waiting = (try? storage.pending.load()) ?? []
            problem = nil
            keepsAnswers = true
        } else if storage.setAsideUnreadableAnswers(), let fresh = try? AttemptQueue(store: storage.pending, sender: client, now: now) {
            // Written by a version that saved answers differently: kept aside rather than deleted.
            queue = fresh
            waiting = []
            problem = "Some answers waiting on this \(Device.model) could not be read, so they cannot be sent. New answers are saved as usual."
            keepsAnswers = true
        } else {
            // Answers she makes now still wait, in memory until the app closes.
            queue = Self.queueInMemory(sender: client, now: now)
            waiting = []
            problem = "This \(Device.model) cannot save answers right now. Answers you give without a connection wait only until the app closes."
            keepsAnswers = false
        }
        self.queue = queue
    }

    private static func queueInMemory(sender: QBankClient, now: @escaping @Sendable () -> Date) -> AttemptQueue {
        do {
            return try AttemptQueue(store: InMemoryPendingAttemptStore(), sender: sender, now: now)
        } catch {
            preconditionFailure("An empty in-memory store always reads: \(error)")
        }
    }

    // MARK: Content

    /// Reads from the server and keeps a copy. Without a connection, or when QBank cannot be reached,
    /// it is the copy saved last; only a failure with nothing saved is thrown.
    func load<Value: Codable & Sendable>(
        _ key: CacheKey<Value>,
        from fetch: () async throws(QBankError) -> Value
    ) async throws(QBankError) -> Loaded<Value> {
        if !connection.isOnline, let saved = try? await cache.value(for: key) {
            return Loaded(value: saved.value, savedAt: saved.savedAt)
        }
        do {
            let value = try await fetch()
            // A copy that cannot be written only means less is saved for later; the screen goes on.
            try? await cache.store(value, for: key, savedAt: now())
            sendIfWaiting()
            return Loaded(value: value, savedAt: nil)
        } catch where Self.fallsBackToSaved(error) {
            guard let saved = try? await cache.value(for: key) else { throw error }
            return Loaded(value: saved.value, savedAt: saved.savedAt)
        }
    }

    /// The copy saved on the phone, without asking the server.
    func saved<Value: Codable & Sendable>(_ key: CacheKey<Value>) async -> Cached<Value>? {
        try? await cache.value(for: key)
    }

    /// Keeps a set's copy on the phone with her place in it, as the runner counts it.
    func keep(_ set: PracticeSet) async {
        guard !isClosed else { return }
        try? await cache.store(set, for: .practiceSet(set.id), savedAt: now())
    }

    /// Saves every course and topic she studies on Home with its sets and questions, so any set can
    /// be practiced without signal, not only the ones she opened. Runs in the background, at most
    /// every few minutes unless `force`. Sets already saved are not loaded again: a set's questions
    /// never change, a new version of a set is a new set. One is only when its row says she has got
    /// further, or begun again, elsewhere, so without signal it opens at the place the row promises.
    /// While answers wait, the copy stays: it counts them, and the server does not have them yet.
    func saveCourses(in catalog: Catalog, force: Bool = false) {
        guard !isClosed, saving == nil, connection.isOnline else { return }
        if !force, let coursesSavedAt, now().timeIntervalSince(coursesSavedAt) < Self.saveInterval { return }
        let studied = catalog.semesters.filter { $0.archivedAt == nil }.flatMap(\.courses) + catalog.topics
        let ids = studied.filter { $0.archivedAt == nil }.map(\.id)
        isSavingCourses = true
        saving = Task {
            if await saveAll(ids) {
                coursesSavedAt = now()
            }
            isSavingCourses = false
            saving = nil
            savedRevision += 1
        }
    }

    /// Waits for a save that is running.
    func finishSavingCourses() async {
        await saving?.value
    }

    /// - Returns: Whether every course was saved.
    private func saveAll(_ ids: [String]) async -> Bool {
        var listedSets: Set<String> = []
        var complete = true
        for id in ids {
            guard !Task.isCancelled else { return false }
            let detail: CourseDetail
            do {
                detail = try await client.course(id: id)
            } catch {
                if Self.fallsBackToSaved(error) || error.needsSignIn { return false }
                complete = false
                continue
            }
            guard !Task.isCancelled else { return false }
            try? await cache.store(detail, for: .course(id), savedAt: now())
            for set in detail.folders.flatMap(\.sets) {
                guard !Task.isCancelled else { return false }
                listedSets.insert(set.id)
                if let saved = try? await cache.value(for: .practiceSet(set.id)), saved.savedAt >= set.importedAt,
                   !waiting.isEmpty || Self.copy(saved.value, matches: set) { continue }
                do {
                    let practice = try await client.practiceSet(id: set.id)
                    guard !Task.isCancelled else { return false }
                    try? await cache.store(practice, for: .practiceSet(set.id), savedAt: now())
                } catch {
                    if Self.fallsBackToSaved(error) || error.needsSignIn { return false }
                    complete = false
                }
            }
        }
        if complete {
            await removeUnlisted(courses: Set(ids), sets: listedSets)
        }
        return complete
    }

    /// Whether the copy of a set saved on the phone still says what its row says: the same sitting,
    /// and the same run when the copy has one.
    private static func copy(_ copy: PracticeSet, matches row: PracticeSetSummary) -> Bool {
        copy.sitting?.answeredQuestionIDs.count == row.sitting?.answeredCount && (copy.run == nil || copy.run == row.run)
    }

    /// Forgets courses no longer on Home and sets no longer in a course. While answers wait, their
    /// sets stay: they name the answers and score them on the phone.
    private func removeUnlisted(courses: Set<String>, sets: Set<String>) async {
        guard waiting.isEmpty, let entries = try? await cache.entries() else { return }
        let coursePrefix = CacheKey<CourseDetail>.course("").name
        let setPrefix = CacheKey<PracticeSet>.practiceSet("").name
        for entry in entries {
            let stale = entry.name.hasPrefix(coursePrefix) && !courses.contains(String(entry.name.dropFirst(coursePrefix.count)))
                || entry.name.hasPrefix(setPrefix) && !sets.contains(String(entry.name.dropFirst(setPrefix.count)))
            if stale {
                try? await cache.remove(named: entry.name)
            }
        }
    }

    /// The courses saved on the phone, in Home's order.
    func savedCourses() async -> [SavedCourse] {
        guard let entries = try? await cache.entries() else { return [] }
        let names = Set(entries.map(\.name))
        let coursePrefix = CacheKey<CourseDetail>.course("").name
        let catalog = await saved(.catalog)?.value
        let homeOrder = (catalog?.semesters.flatMap { semester in
            semester.courses.sorted { ($0.sortOrder, $0.code) < ($1.sortOrder, $1.code) }.map(\.id)
        } ?? []) + (catalog?.topics.map(\.id) ?? [])
        var courses: [SavedCourse] = []
        for entry in entries where entry.name.hasPrefix(coursePrefix) {
            guard let saved = try? await cache.value(for: .course(String(entry.name.dropFirst(coursePrefix.count)))) else { continue }
            let sets = saved.value.folders.flatMap(\.sets)
            let savedSets = sets.filter { names.contains(CacheKey<PracticeSet>.practiceSet($0.id).name) }
            courses.append(SavedCourse(
                id: saved.value.id,
                kind: saved.value.kind,
                code: saved.value.code,
                title: saved.value.title,
                questionCount: saved.value.questionCount,
                savedQuestionCount: savedSets.reduce(0) { $0 + $1.questionCount },
                isComplete: savedSets.count == sets.count,
                savedAt: saved.savedAt
            ))
        }
        let position = { (course: SavedCourse) in homeOrder.firstIndex(of: course.id) ?? homeOrder.count }
        return courses.sorted { (position($0), $0.code) < (position($1), $1.code) }
    }

    // MARK: Answers

    /// Saves her answer on the phone, then sends every waiting answer, this one last. Without a
    /// connection it only saves it.
    ///
    /// - Throws: QBank's refusal when it answered that this answer cannot be saved, or `.storage`
    ///   when the phone could not keep it.
    func submit(_ submission: AttemptSubmission, courseID: String) async throws(QBankError) -> Delivery {
        let id = submission.clientAttemptID
        do {
            try await queue.enqueue(submission, courseID: courseID)
        } catch {
            throw .storage(error)
        }
        waiting = await queue.pending
        guard connection.isOnline else {
            return .waiting(reason: .transport(.notConnectedToInternet))
        }
        var report = await send()
        if report.stoppedBy == nil, waiting.contains(where: { $0.id == id }) {
            // It joined a pass that had already sent everything before it: send it now.
            report = await send()
        }
        if let saved = report.sent.first(where: { $0.clientAttemptID == id }) {
            return .sent(saved)
        }
        if let refused = report.refused.first(where: { $0.attempt.id == id }) {
            if Self.wasAccepted(refused.error) { return .accepted }
            // Said on her screen instead.
            notSaved.removeAll { $0.attempt.id == id }
            throw refused.error
        }
        if waiting.contains(where: { $0.id == id }) {
            return .waiting(reason: report.stoppedBy ?? .transport(.notConnectedToInternet))
        }
        // Another pass sent it. Asking again returns its score: the server answers a repeated id
        // with the attempt it saved.
        return .sent(try await client.recordAttempt(submission))
    }

    /// Sends the waiting answers, oldest first, until none is left or one cannot go yet. A pass
    /// already running is joined. Answers QBank refuses leave the phone and are listed in `notSaved`.
    @discardableResult
    func send() async -> FlushReport {
        if let sending {
            return await sending.value
        }
        guard !isClosed else { return FlushReport(remaining: waiting.count) }
        retry?.cancel()
        retry = nil
        isSending = true
        let task = Task {
            let report = await queue.flush()
            waiting = await queue.pending
            let accepted = report.refused.filter { Self.wasAccepted($0.error) }
            notSaved.append(contentsOf: report.refused.filter { !Self.wasAccepted($0.error) })
            if !report.sent.isEmpty || !accepted.isEmpty {
                deliveries += 1
            }
            isSending = false
            sending = nil
            scheduleRetry(after: report)
            return report
        }
        sending = task
        return await task.value
    }

    /// Clears the list of answers QBank refused, once she has seen it.
    func dismissNotSaved() {
        notSaved.removeAll()
    }

    /// Sends in the background when answers wait and the phone is online, such as at launch or
    /// when the app comes back to the front.
    func sendIfWaiting() {
        guard !isClosed, !waiting.isEmpty, sending == nil, connection.isOnline else { return }
        Task { await send() }
    }

    /// The phone's network came or went.
    func connectionChanged(isOnline: Bool) {
        retry?.cancel()
        retry = nil
        retryDelay = Self.firstRetryDelay
        if isOnline {
            sendIfWaiting()
        }
    }

    /// Stops sending and saving, such as when her session ends. What is on the phone stays.
    func stop() {
        isClosed = true
        retry?.cancel()
        retry = nil
        saving?.cancel()
    }

    /// Stops, then waits for a send or save already under way, so nothing writes to the phone
    /// after this returns. Signing out erases the files next.
    func close() async {
        stop()
        await saving?.value
        _ = await sending?.value
    }

    /// While the phone is online but QBank cannot take the answers yet, such as a server restart,
    /// tries again later, waiting longer each time. Without a connection it waits for one instead,
    /// and a session that ended waits for her to sign in again.
    private func scheduleRetry(after report: FlushReport) {
        guard report.remaining > 0, let reason = report.stoppedBy else {
            retryDelay = Self.firstRetryDelay
            return
        }
        guard connection.isOnline, !reason.needsSignIn, reason.serverCode != .mustChangePassword else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.longestRetryDelay)
        retry = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    // MARK: Waiting answers on screen

    /// The waiting answers counted into the progress the server last reported, each scored on the
    /// phone with the server's rules from its saved question.
    func waitingProgress() async -> WaitingProgress {
        guard !waiting.isEmpty else { return WaitingProgress(answers: [:]) }
        let lookup = await savedQuestions(for: waiting)
        return WaitingProgress(pending: waiting) { attempt in
            guard let question = lookup[attempt.submission.questionID]?.question else { return nil }
            return try? Scoring.score(question.body, response: attempt.submission.response).status
        }
    }

    /// The waiting answers by set, oldest first.
    func waitingGroups() async -> [WaitingGroup] {
        let lookup = await savedQuestions(for: waiting)
        var groups: [WaitingGroup] = []
        for attempt in waiting {
            let found = lookup[attempt.submission.questionID]
            let id = found?.set.id ?? attempt.courseID ?? ""
            let title = found?.set.title ?? found?.courseName ?? "Practice"
            if let index = groups.firstIndex(where: { $0.id == id }) {
                let group = groups[index]
                groups[index] = WaitingGroup(
                    id: id, title: group.title, count: group.count + 1,
                    firstAnsweredAt: min(group.firstAnsweredAt, attempt.queuedAt),
                    lastAnsweredAt: max(group.lastAnsweredAt, attempt.queuedAt)
                )
            } else {
                groups.append(WaitingGroup(id: id, title: title, count: 1, firstAnsweredAt: attempt.queuedAt, lastAnsweredAt: attempt.queuedAt))
            }
        }
        return groups
    }

    private struct SavedQuestion {
        let set: PracticeSetSummary
        /// Its course's code, or its topic's name.
        let courseName: String
        let question: Question?
    }

    /// Each answer's question as saved on the phone: its set, from the saved course, and the
    /// question itself, from the saved set.
    private func savedQuestions(for attempts: [PendingAttempt]) async -> [String: SavedQuestion] {
        var found: [String: SavedQuestion] = [:]
        var sets: [String: PracticeSet?] = [:]
        for courseID in Set(attempts.compactMap(\.courseID)) {
            guard let course = await saved(.course(courseID))?.value else { continue }
            let questionIDs = Set(attempts.filter { $0.courseID == courseID }.map(\.submission.questionID))
            for set in course.folders.flatMap(\.sets) {
                for questionID in set.questionIDs where questionIDs.contains(questionID) && found[questionID] == nil {
                    if sets[set.id] == nil {
                        sets[set.id] = .some(await saved(.practiceSet(set.id))?.value)
                    }
                    let question = sets[set.id]??.questions.first { $0.id == questionID }
                    found[questionID] = SavedQuestion(set: set, courseName: Wording.name(course), question: question)
                }
            }
        }
        return found
    }

    /// A reply in the 2xx range the app cannot read: QBank saved the answer. The queue drops it as
    /// it drops a refusal, but it is not one.
    static func wasAccepted(_ error: QBankError) -> Bool {
        if case .unexpectedResponse(let status, _) = error { return (200..<300).contains(status) }
        return false
    }

    /// No connection, or QBank or a proxy in front of it failing: worth showing the saved copy.
    /// A refusal from QBank itself is said as it is.
    static func fallsBackToSaved(_ error: QBankError) -> Bool {
        error.isTemporary && error != .cancelled
    }
}
