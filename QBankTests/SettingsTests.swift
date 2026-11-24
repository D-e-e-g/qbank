import Foundation
import QBankKit
import Testing
import UIKit
@testable import QBank

@MainActor
struct LookStoreTests {
    @Test func startsOnMatchDevice() {
        #expect(LookStore(defaults: TestApp.freshDefaults()).look == .matchDevice)
    }

    @Test func choiceIsKeptOnThePhone() {
        let defaults = TestApp.freshDefaults()
        LookStore(defaults: defaults).look = .dark
        #expect(LookStore(defaults: defaults).look == .dark)
        #expect(defaults.string(forKey: LookStore.key) == "dark")
    }

    @Test func storesTheWebsWords() {
        #expect(Look.allCases.map(\.rawValue) == ["auto", "light", "dark"])
        #expect(Look.allCases.map(\.label) == ["Match device", "Light", "Dark"])
    }

    @Test func unknownStoredValueMatchesTheDevice() {
        let defaults = TestApp.freshDefaults()
        defaults.set("sepia", forKey: LookStore.key)
        #expect(LookStore(defaults: defaults).look == .matchDevice)
    }

    @Test func matchDeviceHandsTheChoiceToTheSystem() {
        #expect(Look.matchDevice.userInterfaceStyle == .unspecified)
        #expect(Look.light.userInterfaceStyle == .light)
        #expect(Look.dark.userInterfaceStyle == .dark)
    }

    @Test func signingOutKeepsTheLook() async {
        let (app, _) = TestApp.make(StubServer(["POST /api/sign-out": .ok(#"{"status":"ok"}"#)]), account: .student())
        app.look.look = .light
        await app.signOut()
        #expect(app.route == .signedOut)
        #expect(app.look.look == .light)
    }
}

@MainActor
struct ChangePasswordModelTests {
    private func model(_ server: StubServer) -> (ChangePasswordModel, AppModel) {
        let (app, _) = TestApp.make(server, account: .student())
        let model = ChangePasswordModel(app: app)
        model.currentPassword = "synthetic-pass-1"
        model.newPassword = "synthetic-pass-3"
        return (model, app)
    }

    @Test func changeKeepsHerSignedInWithTheFreshToken() async throws {
        let server = StubServer(["POST /api/account/password": .ok(Bodies.signedIn(token: "synthetic-fresh-token"))])
        let (model, app) = model(server)
        await model.save()
        #expect(model.isSaved)
        #expect(model.problem == nil)
        #expect(model.currentPassword.isEmpty && model.newPassword.isEmpty)
        #expect(app.route == .signedIn(.student()))
        #expect(try app.client.storedSession()?.token == "synthetic-fresh-token")
        let body = try #require(server.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"currentPassword":"synthetic-pass-1","newPassword":"synthetic-pass-3"}"#)
    }

    @Test func typingAgainClearsTheSavedLine() async {
        let (model, _) = model(StubServer(["POST /api/account/password": .ok(Bodies.signedIn())]))
        await model.save()
        #expect(model.isSaved)
        model.newPassword = "s"
        #expect(model.isSaved == false)
    }

    @Test(arguments: [
        ("", "synthetic-pass-3", "Enter your current password and a new one."),
        ("synthetic-pass-1", "", "Enter your current password and a new one."),
        ("synthetic-pass-1", "short", "Choose a password of at least 8 characters."),
        ("synthetic-pass-1", String(repeating: "x", count: 129), "Choose a password of at most 128 characters."),
        ("synthetic-pass-1", "synthetic-pass-1", "Choose a new password that is different from your current one."),
    ])
    func rulesAreCheckedBeforeSending(current: String, new: String, problem: String) async {
        let server = StubServer()
        let (model, _) = model(server)
        model.currentPassword = current
        model.newPassword = new
        await model.save()
        #expect(model.problem == problem)
        #expect(server.requests.isEmpty)
    }

    @Test func wrongCurrentPasswordSaysSoAndKeepsHerSignedIn() async {
        let server = StubServer(["POST /api/account/password": .error(401, "invalid_credentials", "That password is not right.")])
        let (model, app) = model(server)
        await model.save()
        #expect(model.problem == "That password is not right.")
        #expect(model.currentPassword.isEmpty)
        #expect(model.newPassword == "synthetic-pass-3")
        #expect(app.route == .signedIn(.student()))
        #expect(model.isSaved == false)
    }

    /// The server's own sentence speaks of a temporary password; Settings says it her way.
    @Test func samePasswordFromTheServerIsWordedForSettings() async {
        let server = StubServer(["POST /api/account/password": .error(400, "same_password", "Choose a password that is different from the temporary one.")])
        let (model, _) = model(server)
        await model.save()
        #expect(model.problem == "Choose a new password that is different from your current one.")
    }

    @Test func endedSessionSignsHerOut() async {
        let server = StubServer(["POST /api/account/password": .error(401, "unauthenticated", "Sign in to continue.")])
        let (model, app) = model(server)
        await model.save()
        #expect(app.route == .signedOut)
        #expect(model.problem == nil)
    }

    @Test func sessionThatCouldNotBeRefreshedSaysSo() async {
        let server = StubServer(["POST /api/account/password": .error(502, "auth_failed", "The password was changed, but the session could not be refreshed.")])
        let (model, _) = model(server)
        await model.save()
        #expect(model.problem == "The password was changed, but the session could not be refreshed.")
    }

    @Test func noSignalIsSaidPlainly() async {
        let (model, app) = model(StubServer(["POST /api/account/password": .offline]))
        await model.save()
        #expect(model.problem == "No connection. Check Wi-Fi or cellular data and try again.")
        #expect(app.route == .signedIn(.student()))
        #expect(model.currentPassword == "synthetic-pass-1")
    }
}

@MainActor
struct DeleteAccountModelTests {
    /// A clock the test moves on by hand.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func model(_ server: StubServer, clock: Clock = Clock(), storage: PhoneStorage = .memory(), connection: Connection = Connection()) -> (DeleteAccountModel, AppModel, InMemorySessionStore) {
        let (app, store) = TestApp.make(server, account: .student(), storage: storage, connection: connection)
        let model = DeleteAccountModel(app: app) { clock.now }
        model.password = "synthetic-pass-1"
        return (model, app, store)
    }

    @Test func aDeleteSendsOnlyHerPasswordAndSignsHerOut() async throws {
        let server = StubServer(["DELETE /api/me": .ok(#"{"status":"deleted"}"#)])
        let (model, app, store) = model(server)
        app.hasLanded = true
        await model.delete()
        #expect(model.problem == nil)
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == nil)
        #expect(app.hasLanded == false)
        #expect(try store.load() == nil)
        #expect(server.calls == ["DELETE /api/me"])
        let body = try #require(server.requests.last?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"password":"synthetic-pass-1"}"#)
    }

    /// Once the account is gone the phone keeps nothing of it, as after a sign-out: no saved
    /// courses, no answers waiting to be sent.
    @Test func aDeleteLeavesNothingOfHersOnThePhone() async throws {
        let storage = PhoneStorage.memory()
        let server = StubServer(["GET /api/semesters": .ok(Bodies.semesters()), "DELETE /api/me": .ok(#"{"status":"deleted"}"#)])
        let (model, app, _) = model(server, storage: storage, connection: Connection(isOnline: false))
        try await AppModelTests.waitingAnswer(app)
        _ = try await app.offline?.load(.catalog) { () async throws(QBankError) in try await app.client.catalog() }
        #expect(model.waitingCount == 1)
        await model.delete()
        #expect(app.offline == nil)

        let (again, _) = TestApp.make(server, account: .student(), storage: storage)
        #expect(again.offline?.waiting.isEmpty == true)
        #expect(await again.offline?.saved(.catalog) == nil)
    }

    /// The server already deleted the account, so a session the phone cannot clear still signs her out
    /// and erases what the phone kept.
    @Test func aDeleteSignsHerOutAndErasesEvenWhenTheSessionWillNotClear() async throws {
        struct Unclearable: SessionStore {
            let inner: InMemorySessionStore
            func load() throws(StorageError) -> StoredSession? { try inner.load() }
            func save(_ session: StoredSession) throws(StorageError) { try inner.save(session) }
            func clear() throws(StorageError) {
                throw StorageError(operation: "clear session", reason: "locked", status: -25308)
            }
        }
        let storage = PhoneStorage.memory()
        let server = StubServer(["DELETE /api/me": .ok(#"{"status":"deleted"}"#)])
        let store = Unclearable(inner: InMemorySessionStore(StoredSession(token: TestApp.token, expiresAt: nil, account: .student())))
        let defaults = TestApp.freshDefaults()
        let client = QBankClient(configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: server, sessionStore: store)
        let app = AppModel(
            client: client,
            look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)),
            storage: storage,
            connection: Connection(isOnline: false)
        )
        try await AppModelTests.waitingAnswer(app)
        let model = DeleteAccountModel(app: app)
        model.password = "synthetic-pass-1"
        await model.delete()
        #expect(model.problem == nil)
        #expect(app.route == .signedOut)
        #expect(app.offline == nil)

        let (again, _) = TestApp.make(server, account: .student(), storage: storage)
        #expect(again.offline?.waiting.isEmpty == true)
    }

    @Test func noPasswordIsAskedForBeforeSending() async {
        let server = StubServer()
        let (model, app, _) = model(server)
        model.password = ""
        await model.delete()
        #expect(model.problem == "Enter your password to delete your account.")
        #expect(server.requests.isEmpty)
        #expect(app.route == .signedIn(.student()))
    }

    @Test func aWrongPasswordSaysSoAndKeepsHerSignedIn() async throws {
        let server = StubServer(["DELETE /api/me": .error(401, "invalid_credentials", "That password is not right.")])
        let (model, app, store) = model(server)
        await model.delete()
        #expect(model.problem == "That password is not right.")
        #expect(model.password.isEmpty)
        #expect(model.canDelete)
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load()?.token == TestApp.token)
    }

    /// Each refusal deletes nothing: she stays signed in and reads the server's sentence.
    @Test(arguments: [
        (409, "in_use", "QBank is still making a set in NURS 310. Wait until it is filed, or cancel it, then delete your account."),
        (403, "admin_cannot_delete_account", "The admin account can't be deleted."),
        (403, "agent_key_not_allowed", "An agent key can't do this. Sign in to QBank to do it."),
        (400, "invalid_request", "Check the fields and try again."),
        (503, "auth_unavailable", "Sign-in is not available right now."),
    ])
    func aRefusalSaysWhyInTheServersWords(status: Int, code: String, message: String) async throws {
        let server = StubServer(["DELETE /api/me": .error(status, code, message)])
        let (model, app, store) = model(server)
        await model.delete()
        #expect(model.problem == message)
        #expect(model.password == "synthetic-pass-1")
        #expect(app.route == .signedIn(.student()))
        #expect(try store.load()?.token == TestApp.token)
    }

    /// Too many wrong passwords: Delete waits until the lock's time has passed, then the line goes.
    @Test func aLockWaitsForItsTime() async {
        let clock = Clock()
        let locked = StubServer.Reply(
            status: 429,
            body: #"{"error":"too_many_attempts","message":"Too many tries. Try again in 15 minutes.","retryAfterSeconds":900}"#,
            headers: ["retry-after": "900"]
        )
        let server = StubServer(["DELETE /api/me": locked])
        let (model, app, _) = model(server, clock: clock)
        await model.delete()
        #expect(model.problem == "Too many tries. Try again in 15 minutes.")
        #expect(model.lockedUntil == clock.now.addingTimeInterval(900))
        #expect(model.canDelete == false)
        #expect(model.password.isEmpty)
        #expect(app.route == .signedIn(.student()))

        model.password = "synthetic-pass-1"
        await model.delete()
        #expect(server.calls == ["DELETE /api/me"], "nothing is sent while locked")

        clock.now += 899
        model.lockEnded()
        #expect(model.canDelete == false)
        clock.now += 1
        model.lockEnded()
        #expect(model.canDelete)
        #expect(model.lockedUntil == nil)
        #expect(model.problem == nil)
    }

    /// A temporary password leads to choosing a new one first, as any call does.
    @Test func aTemporaryPasswordLeadsToChoosingANewOne() async {
        let server = StubServer(["DELETE /api/me": .error(403, "must_change_password", "Choose a new password to continue.")])
        let (model, app, _) = model(server)
        await model.delete()
        #expect(app.route == .choosingPassword(.student()))
        #expect(model.problem == nil)
    }

    @Test func anEndedSessionSignsHerOut() async {
        let server = StubServer(["DELETE /api/me": .error(401, "unauthenticated", "Sign in to continue.")])
        let (model, app, _) = model(server)
        await model.delete()
        #expect(app.route == .signedOut)
        #expect(app.signedOutReason == "Your session ended. Sign in again.")
    }

    @Test func noSignalIsSaidPlainlyAndDeletesNothing() async {
        let (model, app, _) = model(StubServer(["DELETE /api/me": .offline]))
        await model.delete()
        #expect(model.problem == "No connection. Check Wi-Fi or cellular data and try again.")
        #expect(app.route == .signedIn(.student()))
        #expect(model.password == "synthetic-pass-1")
    }

    @Test func onlyAUserAccountIsOfferedIt() {
        #expect(DeleteAccountModel.isOffered(to: .student()))
        #expect(DeleteAccountModel.isOffered(to: .admin) == false)
        #expect(DeleteAccountModel.isOffered(to: nil) == false)
    }
}

@MainActor
struct CatalogModelTests {
    static let twoSemesters = Bodies.catalog([
        Bodies.semester(
            id: "s1", number: 1,
            courses: [
                Bodies.course(id: "c2", code: "NURS 402", order: 2),
                Bodies.course(id: "c1", code: "NURS 406", order: 1),
                Bodies.course(id: "c3", code: "NURS 300", order: 3, archived: true),
            ]),
        Bodies.semester(id: "s2", number: 2),
    ])

    @Test func loadsHerSemesters() async throws {
        let (app, _) = TestApp.make(StubServer(["GET /api/semesters": .ok(Self.twoSemesters)]), account: .student())
        let catalog = CatalogModel(app: app)
        await catalog.load()
        let semesters = try #require(catalog.semesters)
        #expect(semesters.map(\.name) == ["Semester 1", "Semester 2"])
        #expect(CatalogModel.summary(of: semesters[0]) == "NURS 406, NURS 402 · 1 archived")
        #expect(CatalogModel.summary(of: semesters[1]) == "No courses yet")
        #expect(CatalogModel.nextSemesterNumber(after: semesters) == 3)
    }

    @Test func aCourseSheetStartsFromTheListItWasOpenedWith() throws {
        let server = StubServer()
        let (app, _) = TestApp.make(server, account: .student())
        let catalog = CatalogModel(app: app, catalog: try Bodies.decodeCatalog(Self.twoSemesters))
        #expect(CourseEditModel(catalog: catalog, id: "c1").code == "NURS 406")
        #expect(SemesterModel(catalog: catalog, id: "s2").name == "Semester 2")
        #expect(server.requests.isEmpty, "nothing is read before she saves")
    }

    @Test func onlyStudentsEditTheCatalog() {
        #expect(CatalogModel(app: TestApp.make(StubServer(), account: .student()).0).isEditable)
        #expect(CatalogModel(app: TestApp.make(StubServer(), account: .admin).0).isEditable == false)
    }

    @Test func failedFirstLoadSaysWhyAndAFailedReloadKeepsTheList() async {
        let server = StubServer(["GET /api/semesters": .offline])
        let (app, _) = TestApp.make(server, account: .student())
        let catalog = CatalogModel(app: app)
        await catalog.load()
        #expect(catalog.semesters == nil)
        #expect(catalog.loadProblem == "No connection. Check Wi-Fi or cellular data and try again.")
        server["GET /api/semesters"] = .ok(Self.twoSemesters)
        await catalog.load()
        #expect(catalog.loadProblem == nil)
        server["GET /api/semesters"] = .offline
        await catalog.load()
        #expect(catalog.semesters?.count == 2)
        #expect(catalog.loadProblem == nil)
    }

    @Test func endedSessionSignsHerOut() async {
        let server = StubServer(["GET /api/semesters": .error(401, "unauthenticated", "Sign in to continue.")])
        let (app, _) = TestApp.make(server, account: .student())
        await CatalogModel(app: app).load()
        #expect(app.route == .signedOut)
    }
}

@MainActor
struct SemesterModelTests {
    private func loaded(_ server: StubServer) async -> CatalogModel {
        let (app, _) = TestApp.make(server, account: .student())
        let catalog = CatalogModel(app: app)
        await catalog.load()
        return catalog
    }

    @Test func startsFromWhatTheServerHas() async {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1, name: "Fall", startsOn: "2026-09-01")]))])
        let model = SemesterModel(catalog: await loaded(server), id: "s1")
        #expect(model.name == "Fall")
        #expect(CalendarDay.text(from: model.startsOn) == "2026-09-01")
        #expect(model.endsOn == nil)
    }

    @Test func saveSendsTheNameAndDatesAndAClearedDateAsNull() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1, endsOn: "2026-12-18")]))])
        let catalog = await loaded(server)
        let model = SemesterModel(catalog: catalog, id: "s1")
        model.name = "  Fall 2026 "
        model.startsOn = CalendarDay.date(from: "2026-09-01")
        model.endsOn = nil
        server["PATCH /api/semesters/s1"] = .ok(Bodies.semester(id: "s1", number: 1, name: "Fall 2026", startsOn: "2026-09-01"))
        server["GET /api/semesters"] = .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1, name: "Fall 2026", startsOn: "2026-09-01")]))
        await model.save()
        let patch = try #require(server.requests.first { $0.httpMethod == "PATCH" })
        let body = try #require(patch.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"endsOn":null,"name":"  Fall 2026 ","startsOn":"2026-09-01"}"#)
        #expect(model.isSaved)
        #expect(model.name == "Fall 2026")
        #expect(catalog.semester(id: "s1")?.name == "Fall 2026")
        model.name = "Fall"
        #expect(model.isSaved == false)
    }

    @Test func blankNameIsCaughtBeforeSending() async {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1)]))])
        let model = SemesterModel(catalog: await loaded(server), id: "s1")
        model.name = "   "
        await model.save()
        #expect(model.saveProblem == "Semester name is required.")
        #expect(server.calls == ["GET /api/semesters"])
    }

    @Test func addsACourseAndEmptiesTheFields() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1)]))])
        let catalog = await loaded(server)
        let model = SemesterModel(catalog: catalog, id: "s1")
        model.newCode = "NURS 406"
        model.newTitle = "Mental Health"
        server["POST /api/courses"] = StubServer.Reply(status: 201, body: Bodies.course(id: "c9", code: "NURS 406"))
        server["GET /api/semesters"] = .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c9", code: "NURS 406")])]))
        let added = await model.addCourse()
        let body = try #require(server.requests.first { $0.httpMethod == "POST" }?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"code":"NURS 406","semesterId":"s1","title":"Mental Health"}"#)
        #expect(model.addProblem == nil)
        #expect(added?.id == "c9")
        #expect(model.newCode.isEmpty && model.newTitle.isEmpty)
        #expect(model.semester?.courses.map(\.code) == ["NURS 406"])
    }

    @Test(arguments: [("", "Mental Health", "Course code is required."), ("NURS 406", " ", "Course name is required.")])
    func courseNeedsACodeAndAName(code: String, title: String, problem: String) async {
        let server = StubServer(["GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1)]))])
        let model = SemesterModel(catalog: await loaded(server), id: "s1")
        model.newCode = code
        model.newTitle = title
        #expect(await model.addCourse() == nil)
        #expect(model.addProblem == problem)
        #expect(server.calls == ["GET /api/semesters"])
    }

    @Test func takenCodeSaysWhyAndKeepsTheFields() async {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.catalog([Bodies.semester(id: "s1", number: 1)])),
            "POST /api/courses": .error(409, "request_refused", "This semester already has a course with the code NURS 406."),
        ])
        let model = SemesterModel(catalog: await loaded(server), id: "s1")
        model.newCode = "NURS 406"
        model.newTitle = "Mental Health"
        #expect(await model.addCourse() == nil)
        #expect(model.addProblem == "This semester already has a course with the code NURS 406.")
        #expect(model.newCode == "NURS 406")
    }
}

@MainActor
struct CourseEditModelTests {
    private static let catalog = Bodies.catalog([
        Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c1", code: "NURS 406")]),
        Bodies.semester(id: "s2", number: 2),
    ])
    private static let renamed = Bodies.catalog([
        Bodies.semester(id: "s1", number: 1, courses: [Bodies.course(id: "c1", code: "NURS 410")]),
        Bodies.semester(id: "s2", number: 2),
    ])

    private func model(_ server: StubServer) async -> CourseEditModel {
        let (app, _) = TestApp.make(server, account: .student())
        let catalog = CatalogModel(app: app)
        await catalog.load()
        return CourseEditModel(catalog: catalog, id: "c1")
    }

    @Test func renamesInItsOwnSemester() async throws {
        let server = StubServer(["GET /api/semesters": .ok(Self.catalog)])
        let model = await model(server)
        #expect(model.semesterID == "s1")
        #expect(!model.hasChanges)
        model.code = "NURS 410"
        #expect(model.hasChanges)
        server["PATCH /api/courses/c1"] = .ok(Bodies.course(id: "c1", code: "NURS 410"))
        server["GET /api/semesters"] = .ok(Self.renamed)
        await model.save()
        let body = try #require(server.requests.first { $0.httpMethod == "PATCH" }?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"code":"NURS 410","semesterId":"s1","title":"Invented NURS 406"}"#)
        #expect(model.note == "Saved.")
        #expect(model.problem == nil)
        #expect(model.catalog.semester(id: "s1")?.courses.map(\.code) == ["NURS 410"])
    }

    @Test func blankNameIsCaughtBeforeSending() async {
        let server = StubServer(["GET /api/semesters": .ok(Self.catalog)])
        let model = await model(server)
        model.title = ""
        await model.save()
        #expect(model.problem == "Course name is required.")
        #expect(server.calls == ["GET /api/semesters"])
    }

    @Test func refusalSaysWhy() async {
        let server = StubServer([
            "GET /api/semesters": .ok(Self.catalog),
            "PATCH /api/courses/c1": .error(409, "request_refused", "This semester already has a course with the code NURS 402."),
        ])
        let model = await model(server)
        model.code = "NURS 402"
        await model.save()
        #expect(model.problem == "This semester already has a course with the code NURS 402.")
        #expect(model.note == nil)
        #expect(model.code == "NURS 402")
    }

    @Test func editingClearsTheNote() async {
        let server = StubServer(["GET /api/semesters": .ok(Self.catalog), "PATCH /api/courses/c1": .ok(Bodies.course(id: "c1", code: "NURS 406"))])
        let model = await model(server)
        await model.save()
        #expect(model.note == "Saved.")
        model.title = "Psych"
        #expect(model.note == nil)
    }
}

struct CalendarDayTests {
    @Test(arguments: ["2026-09-01", "2027-02-28", "2028-02-29", "2026-12-31"])
    func roundTrips(day: String) throws {
        let date = try #require(CalendarDay.date(from: day))
        #expect(CalendarDay.text(from: date) == day)
    }

    @Test func roundTripsInAnyTimeZone() throws {
        for zone in ["Pacific/Kiritimati", "America/Los_Angeles", "UTC", "Pacific/Pago_Pago"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let date = try #require(CalendarDay.date(from: "2026-09-01", calendar: calendar))
            #expect(CalendarDay.text(from: date, calendar: calendar) == "2026-09-01", "\(zone)")
        }
    }

    @Test(arguments: [nil, "", "2026-13-01", "2026-02-30", "next week"])
    func notADay(text: String?) {
        #expect(CalendarDay.date(from: text) == nil)
    }
}

/// Export my bank: one bank archive file, from the phone's bank for a free account and from the server
/// for the others, named for what it is and the day. Invented data only.
@MainActor
struct BankExportTests {
    private let day = Date(timeIntervalSince1970: 1_795_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bank-export-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func freeApp(_ bank: LocalBank, network: StubServer = StubServer()) -> AppModel {
        let store = InMemorySessionStore(StoredSession(token: TestApp.token, account: .student()))
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: network, sessionStore: store
        )
        let defaults = TestApp.freshDefaults()
        return AppModel(
            client: client, kind: .free, bank: bank, look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)), highlighter: HighlighterStore(defaults: defaults),
            aiConsent: AIConsentStore(defaults: defaults), storage: .memory()
        )
    }

    @Test func onlyAUserAccountIsOfferedIt() {
        #expect(BankExport.isOffered(to: .student()))
        #expect(BankExport.isOffered(to: .admin) == false)
        #expect(BankExport.isOffered(to: nil) == false)
    }

    @Test func theFileNameSaysWhatItIsAndTheDay() {
        #expect(BankExport.fileName(on: day, calendar: utc) == "qbank-bank-2026-11-18.json")
    }

    @Test func aFreeAccountSharesTheArchiveOfItsBankOnThePhone() async throws {
        let store = try LocalStore.inMemory()
        let bank = LocalBank(store: store, clock: { Date(timeIntervalSince1970: 1_795_000_000) })
        let network = StubServer()
        let app = freeApp(bank, network: network)
        _ = try await app.client.createTopic(title: "Invented Sleep Notes")
        let before = try BankArchive.counts(of: store)
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try await app.exportBank(in: directory, now: day)

        #expect(file.lastPathComponent == BankExport.fileName(on: day))
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format": "qbank-bank-archive""#))
        #expect(text.contains(#""writtenBy": "phone""#))
        #expect(text.contains("Invented Sleep Notes"))
        let fresh = try LocalStore.inMemory()
        #expect(try BankArchive.read(data, into: fresh) == before)
        #expect(network.calls.isEmpty, "a bank on the phone is written from the phone")
        #expect(try BankArchive.counts(of: store) == before, "exporting reads the bank and changes nothing")
    }

    @Test func anAccountWithItsBankOnTheServerSharesTheFileTheServerWrites() async throws {
        let document = #"{"format":"qbank-bank-archive","version":1}"#
        let server = StubServer(["GET /api/me/bank": .ok(document)])
        let (app, _) = TestApp.make(server, account: .student())
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try await app.exportBank(in: directory, now: day)

        #expect(server.calls == ["GET /api/me/bank"])
        #expect(try String(contentsOf: file, encoding: .utf8) == document)
        #expect(file.lastPathComponent == BankExport.fileName(on: day))
    }

    @Test func anInvitedSignInAfterAFreeAccountSharesTheServersFileNotThePhonesBank() async throws {
        let document = #"{"format":"qbank-bank-archive","version":1}"#
        let network = StubServer(["POST /api/sign-in/password": .ok(Bodies.signedIn()), "GET /api/me/bank": .ok(document)])
        let app = freeApp(LocalBank(store: try LocalStore.inMemory()), network: network)
        _ = try await app.client.createTopic(title: "Invented Free Notes")
        let signIn = SignInModel(app: app)
        signIn.email = "student@example.com"
        signIn.password = "synthetic-pass-1"
        await signIn.signIn()
        #expect(app.route == .signedIn(.student()))
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try await app.exportBank(in: directory, now: day)

        #expect(network.calls == ["POST /api/sign-in/password", "GET /api/me/bank"])
        #expect(try String(contentsOf: file, encoding: .utf8) == document)
    }

    @Test func aServerThatCannotBeReachedLeavesNoFile() async throws {
        let server = StubServer(["GET /api/me/bank": .error(503, "unavailable", "QBank is busy.")])
        let (app, _) = TestApp.make(server, account: .student())
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: QBankError.self) { try await app.exportBank(in: directory, now: day) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aNewExportReplacesTheLastOneWaitingToBeShared() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try BankExport.write(Data("one".utf8), on: day, in: directory, calendar: utc)
        let next = day.addingTimeInterval(86_400)
        _ = try BankExport.write(Data("two".utf8), on: next, in: directory, calendar: utc)
        let waiting = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("BankExport").path)
        #expect(waiting == ["qbank-bank-2026-11-19.json"])
    }
}
