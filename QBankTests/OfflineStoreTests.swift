import Foundation
import QBankKit
import Synchronization
import Testing
@testable import QBank

/// The phone's store for one account: saved courses and sets, and answers waiting to be sent.
@MainActor
struct OfflineStoreTests {
    static func client(
        _ transport: any HTTPTransport,
        session: StoredSession = StoredSession(token: TestApp.token, expiresAt: nil, account: .student())
    ) -> QBankClient {
        QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!),
            transport: transport,
            sessionStore: InMemorySessionStore(session)
        )
    }

    /// A store whose retries never fire unless the test gives it a way to wait.
    static func store(
        _ transport: any HTTPTransport,
        storage: PhoneStorage.Account,
        connection: Connection = Connection(),
        session: StoredSession = StoredSession(token: TestApp.token, expiresAt: nil, account: .student()),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping (Duration) async throws -> Void = { _ in throw CancellationError() }
    ) -> OfflineStore {
        OfflineStore(
            accountID: "a1", client: client(transport, session: session), connection: connection,
            storage: storage, now: now, sleep: sleep
        )
    }

    static func answer(_ id: String, question: String = "q-sata") -> AttemptSubmission {
        AttemptSubmission(clientAttemptID: id, questionID: question, response: .sata(picks: [0, 2]))
    }

    static func saved(_ id: String, question: String = "q-sata") -> StubServer.Reply {
        StubServer.Reply(status: 201, body: PracticeModelTests.saved(id: id, question: question, status: "correct", points: 2, max: 2))
    }

    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QBankTests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Answers

    @Test func waitingAnswersSurviveARelaunchAndGoInOrder() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = PhoneStorage.files(root: folder)
        let server = StubServer()

        let first = Self.store(server, storage: storage.open("a1"), connection: Connection(isOnline: false))
        for id in ["a1", "a2", "a3"] {
            #expect(try await first.submit(Self.answer(id), courseID: "c1") == .waiting(reason: .transport(.notConnectedToInternet)))
        }
        #expect(first.waiting.map(\.id) == ["a1", "a2", "a3"])
        #expect(server.requests.isEmpty)

        // The app is closed and opened again, online.
        let relaunched = Self.store(server, storage: storage.open("a1"))
        #expect(relaunched.waiting.map(\.id) == ["a1", "a2", "a3"])
        #expect(relaunched.waiting.allSatisfy { $0.courseID == "c1" })
        server.script("POST /api/attempts", [Self.saved("a1"), Self.saved("a2"), Self.saved("a3")])
        let report = await relaunched.send()
        #expect(report.sent.map(\.clientAttemptID) == ["a1", "a2", "a3"])
        #expect(server.sentAttemptIDs == ["a1", "a2", "a3"])
        #expect(relaunched.waiting.isEmpty)
        #expect(relaunched.deliveries == 1)

        #expect(Self.store(server, storage: storage.open("a1")).waiting.isEmpty, "the phone forgot them once QBank had them")
    }

    @Test func theSameAnswerWaitsOnce() async throws {
        let store = Self.store(StubServer(), storage: PhoneStorage.memory().open("a1"), connection: Connection(isOnline: false))
        _ = try await store.submit(Self.answer("a1"), courseID: "c1")
        _ = try await store.submit(Self.answer("a1"), courseID: "c1")
        #expect(store.waiting.map(\.id) == ["a1"])
    }

    @Test func aLostReplyIsSentAgainAndCountedOnce() async throws {
        // The fake server saves each id once and answers a repeat with what it saved, as QBank does.
        let server = FakeQBankServer(signedIn: true)
        let transport = LosesFirstReply(server: server)
        let session = FakeQBankServer.storedStudentSession()
        let store = Self.store(transport, storage: PhoneStorage.memory().open("a1"), session: session)
        let question = "mixed-v1-q0"
        let submission = AttemptSubmission(clientAttemptID: AttemptSubmission.newID(), questionID: question, response: .single(choice: 0))

        let delivery = try await store.submit(submission, courseID: FakeQBankServer.mentalHealthID)
        #expect(delivery == .waiting(reason: .transport(.networkConnectionLost)), "the server saved it, but the reply was lost")
        #expect(store.waiting.map(\.id) == [submission.clientAttemptID])

        let report = await store.send()
        #expect(report.sent.first?.replayed == true)
        #expect(store.waiting.isEmpty)
        let course = try await Self.client(server, session: session).course(id: FakeQBankServer.mentalHealthID)
        let mixed = try #require(course.folders.flatMap(\.sets).first { $0.id == "mixed-v1" })
        #expect(mixed.answeredCount == 1, "sent twice, counted once")
    }

    @Test func aDroppedConnectionMidwayKeepsTheRestInOrder() async throws {
        let server = StubServer()
        let connection = Connection(isOnline: false)
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"), connection: connection)
        for id in ["a1", "a2", "a3"] {
            _ = try await store.submit(Self.answer(id), courseID: "c1")
        }
        connection.update(isOnline: true)
        server.script("POST /api/attempts", [Self.saved("a1"), .offline])
        let partial = await store.send()
        #expect(partial.sent.map(\.clientAttemptID) == ["a1"])
        #expect(partial.stoppedBy == .transport(.notConnectedToInternet))
        #expect(store.waiting.map(\.id) == ["a2", "a3"])

        server.script("POST /api/attempts", [Self.saved("a2"), Self.saved("a3")])
        let rest = await store.send()
        #expect(rest.sent.map(\.clientAttemptID) == ["a2", "a3"])
        #expect(server.sentAttemptIDs == ["a1", "a2", "a2", "a3"], "the one that failed goes again first, with its id")
        #expect(store.waiting.isEmpty)
    }

    @Test func aRefusedAnswerLeavesAndTheRestGo() async throws {
        let server = StubServer()
        let connection = Connection(isOnline: false)
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"), connection: connection)
        for id in ["a1", "a2", "a3"] {
            _ = try await store.submit(Self.answer(id), courseID: "c1")
        }
        connection.update(isOnline: true)
        server.script(
            "POST /api/attempts",
            [
                Self.saved("a1"), .error(404, "question_not_found", "That question is not in the app."), Self.saved("a3"),
            ])
        await store.send()
        #expect(server.sentAttemptIDs == ["a1", "a2", "a3"])
        #expect(store.waiting.isEmpty)
        #expect(store.notSaved.map(\.attempt.id) == ["a2"])
        #expect(store.notSaved.first?.error.serverCode == .questionNotFound)
    }

    @Test func whileOnlineItTriesAgainWaitingLongerEachTime() async throws {
        let server = StubServer(["POST /api/attempts": .error(503, "auth_unavailable", "Sign-in is not available right now.")])
        var delays: [Duration] = []
        let store = Self.store(
            server, storage: PhoneStorage.memory().open("a1"),
            sleep: { delay in
                delays.append(delay)
                if delays.count > 3 { throw CancellationError() }
            })
        let delivery = try await store.submit(Self.answer("a1"), courseID: "c1")
        #expect(delivery == .waiting(reason: .server(ServerError(status: 503, code: .authUnavailable, message: "Sign-in is not available right now."))))
        try await waitUntil { delays.count == 4 }
        #expect(delays == [.seconds(5), .seconds(10), .seconds(20), .seconds(40)])
        #expect(server.sentAttemptIDs == ["a1", "a1", "a1", "a1"])
        #expect(store.waiting.map(\.id) == ["a1"])
    }

    @Test func withoutANetworkItWaitsForOneInsteadOfTrying() async throws {
        let server = StubServer(["POST /api/attempts": .offline])
        var retried = false
        let connection = Connection()
        let store = Self.store(
            server, storage: PhoneStorage.memory().open("a1"), connection: connection,
            sleep: { _ in
                retried = true
                throw CancellationError()
            })
        connection.update(isOnline: false)
        _ = try await store.submit(Self.answer("a1"), courseID: "c1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!retried)
        #expect(server.requests.isEmpty)

        server["POST /api/attempts"] = Self.saved("a1")
        connection.update(isOnline: true)
        store.connectionChanged(isOnline: true)
        try await waitUntil { store.waiting.isEmpty }
        #expect(server.sentAttemptIDs == ["a1"])
    }

    @Test func aReplyTheAppCannotReadStillMeansQBankHasTheAnswer() async throws {
        let server = StubServer(["POST /api/attempts": StubServer.Reply(status: 201, body: "{}")])
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"))
        #expect(try await store.submit(Self.answer("a1"), courseID: "c1") == .accepted)
        #expect(store.waiting.isEmpty)
        #expect(store.notSaved.isEmpty)
        #expect(store.deliveries == 1)
    }

    @Test func refusedAnswersAreListedUntilDismissed() async throws {
        let server = StubServer()
        let connection = Connection(isOnline: false)
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"), connection: connection)
        for id in ["a1", "a2"] {
            _ = try await store.submit(Self.answer(id), courseID: "c1")
        }
        connection.update(isOnline: true)
        server.script(
            "POST /api/attempts",
            [
                StubServer.Reply(status: 200, body: "not json"), .error(400, "invalid_response", "That answer does not fit the question."),
            ])
        await store.send()
        #expect(store.notSaved.map(\.attempt.id) == ["a2"], "a 2xx it cannot read is not a refusal")
        #expect(store.deliveries == 1)
        store.dismissNotSaved()
        #expect(store.notSaved.isEmpty)
    }

    @Test func anUnreadableAnswersFileIsKeptAsideAndNewAnswersStillSave() async throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = PhoneStorage.files(root: folder)
        let account = folder.appendingPathComponent("Accounts/a1", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try Data("written by another version".utf8).write(to: account.appendingPathComponent("pending-attempts.json"))

        let store = Self.store(StubServer(), storage: storage.open("a1"), connection: Connection(isOnline: false))
        #expect(store.problem == "Some answers waiting on this \(Device.model) could not be read, so they cannot be sent. New answers are saved as usual.")
        #expect(store.keepsAnswers)
        #expect(store.waiting.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: account.path())
        #expect(names.contains { $0.hasPrefix("pending-attempts.unreadable-") }, "kept, not deleted")

        _ = try await store.submit(Self.answer("a1"), courseID: "c1")
        let relaunched = Self.store(StubServer(), storage: storage.open("a1"), connection: Connection(isOnline: false))
        #expect(relaunched.waiting.map(\.id) == ["a1"])
        #expect(relaunched.problem == nil)
    }

    @Test func whenThePhoneCannotKeepAnswersItSaysSo() async throws {
        let broken = PhoneStorage.Account(cache: InMemoryContentCache(), pending: UnreadableStore())
        let store = Self.store(StubServer(), storage: broken, connection: Connection(isOnline: false))
        #expect(!store.keepsAnswers)
        #expect(store.problem == "This \(Device.model) cannot save answers right now. Answers you give without a connection wait only until the app closes.")
        _ = try await store.submit(Self.answer("a1"), courseID: "c1")
        #expect(store.waiting.map(\.id) == ["a1"], "they still wait while the app runs")
    }

    // MARK: Content

    @Test func loadShowsTheSavedCopyOnlyWhenQBankCannotBeReached() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.semesters())])
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"), now: { savedAt })
        let client = Self.client(server)
        let fresh = try await store.load(.catalog) { () async throws(QBankError) in try await client.catalog() }
        #expect(fresh.savedAt == nil)

        for reply in [StubServer.Reply.offline, .error(503, "auth_unavailable", "Down."), StubServer.Reply(status: 502, body: "<html>")] {
            server["GET /api/semesters"] = reply
            let copy = try await store.load(.catalog) { () async throws(QBankError) in try await client.catalog() }
            #expect(copy.savedAt == savedAt)
            #expect(copy.value == fresh.value)
        }

        server["GET /api/semesters"] = .error(404, "request_refused", "Gone.")
        await #expect(throws: QBankError.server(ServerError(status: 404, code: .requestRefused, message: "Gone."))) {
            _ = try await store.load(.catalog) { () async throws(QBankError) in try await client.catalog() }
        }
    }

    @Test func nothingSavedAndNoSignalFails() async {
        let server = StubServer(["GET /api/semesters": .offline])
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"), connection: Connection(isOnline: false))
        let client = Self.client(server)
        await #expect(throws: QBankError.transport(.notConnectedToInternet)) {
            _ = try await store.load(.catalog) { () async throws(QBankError) in try await client.catalog() }
        }
        #expect(server.calls == ["GET /api/semesters"], "with nothing saved it tries the server anyway")
    }

    @Test func savingCoursesSavesEverySetOnceAndForgetsReplacedOnes() async throws {
        let course = Bodies.courseDetail(sets: [Bodies.set(id: "set1"), Bodies.set(id: "set2")])
        let server = StubServer([
            "GET /api/courses/c1": .ok(course),
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
            "GET /api/practice-sets/set2": .ok(PracticeModelTests.practiceSet()),
            "GET /api/practice-sets/set3": .ok(PracticeModelTests.practiceSet()),
        ])
        let semesters = try Bodies.decodeCatalog(
            Bodies.semesters([
                Bodies.course(id: "c1", code: "NURS 101"),
                Bodies.course(id: "c9", code: "NURS 900", archived: true),
            ]))
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"))

        store.saveCourses(in: semesters)
        #expect(store.isSavingCourses)
        await store.finishSavingCourses()
        #expect(!store.isSavingCourses)
        #expect(server.calls == ["GET /api/courses/c1", "GET /api/practice-sets/set1", "GET /api/practice-sets/set2"], "archived courses are not saved")
        #expect(store.savedRevision == 1)

        store.saveCourses(in: semesters)
        await store.finishSavingCourses()
        #expect(server.calls.count == 3, "it saved them a moment ago")

        server["GET /api/courses/c1"] = .ok(Bodies.courseDetail(sets: [Bodies.set(id: "set2"), Bodies.set(id: "set3")]))
        store.saveCourses(in: semesters, force: true)
        await store.finishSavingCourses()
        #expect(server.calls.suffix(2) == ["GET /api/courses/c1", "GET /api/practice-sets/set3"], "a saved set is not loaded again")
        #expect(await store.saved(.practiceSet("set1")) == nil, "a set no longer in the course is forgotten")
        #expect(await store.saved(.practiceSet("set3")) != nil)

        let courses = await store.savedCourses()
        #expect(courses.map(\.code) == ["NURS 101"])
        #expect(courses.first?.questionCount == 10, "the course's own count")
        #expect(courses.first?.savedQuestionCount == 4)
        #expect(courses.first?.isComplete == true)
    }

    @Test func savingStopsWithoutSignalAndKeepsWhatItHas() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [Bodies.set(id: "set1"), Bodies.set(id: "set2")])),
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
            "GET /api/practice-sets/set2": .offline,
        ])
        let semesters = try Bodies.decodeCatalog(Bodies.semesters())
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"))
        store.saveCourses(in: semesters)
        await store.finishSavingCourses()
        let course = try #require(await store.savedCourses().first)
        #expect(course.savedQuestionCount == 2)
        #expect(!course.isComplete)
        #expect(Wording.savedCourse(course).hasPrefix("2 of 10 questions · updated "))

        server["GET /api/practice-sets/set2"] = .ok(PracticeModelTests.practiceSet())
        store.saveCourses(in: semesters)
        await store.finishSavingCourses()
        #expect(await store.savedCourses().first?.isComplete == true, "an unfinished save tries again without waiting")
    }

    @Test func waitingAnswersAreGroupedByTheirSet() async throws {
        let server = StubServer([
            "GET /api/courses/c1": .ok(Bodies.courseDetail(sets: [Bodies.set(id: "set1", title: "Rights, Law, and Ethics", questionIDs: ["q-sata", "q-single"])])),
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
        ])
        let clock = Locked(Date(timeIntervalSince1970: 1_790_000_000))
        let connection = Connection()
        let store = Self.store(server, storage: PhoneStorage.memory().open("a1"), connection: connection, now: { clock.value })
        let semesters = try Bodies.decodeCatalog(Bodies.semesters())
        store.saveCourses(in: semesters)
        await store.finishSavingCourses()

        connection.update(isOnline: false)
        _ = try await store.submit(Self.answer("x1", question: "q-sata"), courseID: "c1")
        clock.value = clock.value.addingTimeInterval(240)
        _ = try await store.submit(AttemptSubmission(clientAttemptID: "x2", questionID: "q-single", response: .single(choice: 1)), courseID: "c1")
        _ = try await store.submit(Self.answer("x3", question: "q-elsewhere"), courseID: "c2")

        let groups = await store.waitingGroups()
        #expect(groups.map(\.title) == ["Rights, Law, and Ethics", "Practice"])
        #expect(groups.map(\.count) == [2, 1])
        #expect(groups.first?.firstAnsweredAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(groups.first?.lastAnsweredAt == Date(timeIntervalSince1970: 1_790_000_240))

        let progress = await store.waitingProgress()
        #expect(progress.answers["q-sata"]?.status == .correct, "scored on the phone from the saved question")
        #expect(progress.answers["q-single"]?.status == .incorrect)
        #expect(progress.answers["q-elsewhere"]?.status == nil, "its question is not saved")
    }
}

/// Passes requests to the fake server, but loses the reply to the first answer after the server saved it.
private final class LosesFirstReply: HTTPTransport {
    let server: FakeQBankServer
    private let lost = Mutex(false)

    init(server: FakeQBankServer) {
        self.server = server
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try await server.send(request)
        let losesThis =
            request.url?.path() == "/api/attempts"
            && lost.withLock { lost in
                defer { lost = true }
                return !lost
            }
        if losesThis { throw URLError(.networkConnectionLost) }
        return reply
    }
}

/// A pending-answers store whose file can never be read.
private struct UnreadableStore: PendingAttemptStore {
    func load() throws(StorageError) -> [PendingAttempt] {
        throw StorageError(operation: "read unsent answers", reason: "unreadable")
    }

    func save(_ attempts: [PendingAttempt]) throws(StorageError) {}
}
