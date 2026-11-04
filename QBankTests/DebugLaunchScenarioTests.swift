import Foundation
import QBankKit
import Testing
@testable import QBank

/// Serialized: the network notifications reach every scenario model alive in the process.
@MainActor
@Suite(.serialized)
struct DebugLaunchScenarioTests {
    /// A scenario's model with a phone folder of its own, so tests running side by side never share one.
    static func launch(_ environment: [String: String], folder: URL = OfflineStoreTests.temporaryFolder()) -> AppModel? {
        DebugLaunchScenario.makeModel(environment: environment, phoneFolder: folder)
    }

    static func launch(_ scenario: String) -> AppModel? {
        launch([DebugLaunchScenario.scenarioKey: scenario])
    }
    @Test func normalLaunchHasNoScenario() throws {
        #expect(try DebugLaunchScenario.scenario(in: [:]) == nil)
        #expect(Self.launch([:]) == nil)
    }

    @Test func signedOutScenarioStartsOnSignIn() throws {
        let environment = [DebugLaunchScenario.scenarioKey: "signed-out"]
        #expect(try DebugLaunchScenario.scenario(in: environment) == .signedOut)
        #expect(Self.launch(environment)?.route == .signedOut)
    }

    @Test func signedInScenarioStartsOnHomeAndLandsOnMentalHealth() async throws {
        let app = try #require(Self.launch("signed-in"))
        #expect(app.account?.email == FakeQBankServer.student.email)
        await app.refreshSession()
        let home = HomeModel(app: app)
        await home.load()
        #expect(home.semesters?.map(\.name) == ["Semester 1", "Semester 2"])
        #expect(await home.landingCourse() == CourseRoute(id: FakeQBankServer.mentalHealthID, name: "NURS 310"))
    }

    @Test func examInProgressScenarioLeavesAnExamOverWeeks1And2Going() async throws {
        let app = try #require(Self.launch("exam-in-progress"))
        #expect(app.account?.email == FakeQBankServer.student.email)
        let setup = try await app.client.examSetup(courseID: FakeQBankServer.mentalHealthID)
        let running = try #require(setup.inProgress)
        #expect(running.weeks == ["Week 1", "Week 2"])
        #expect(setup.exams.count == 3, "her past exams as in signed-in")
    }

    /// Through the fake server: a wrong password deletes nothing, the right one deletes her account,
    /// and then it neither works on this phone nor signs in again.
    @Test func signedInScenarioDeletesHerAccountWithHerPassword() async throws {
        let app = try #require(Self.launch("signed-in"))
        let model = DeleteAccountModel(app: app)
        model.password = "not-it"
        await model.delete()
        #expect(model.problem == "That password is not right.")
        #expect(app.account?.email == FakeQBankServer.student.email)

        model.password = FakeQBankServer.student.password
        await model.delete()
        #expect(app.route == .signedOut)
        let error = await #expect(throws: QBankError.self) {
            try await app.client.signIn(email: FakeQBankServer.student.email, password: FakeQBankServer.student.password)
        }
        #expect(error?.serverCode == .invalidCredentials)
    }

    /// A set still being written in one of her courses holds her account until it is filed.
    @Test func makerScenarioCannotDeleteWhileASetIsBeingWritten() async throws {
        let app = try #require(Self.launch("maker"))
        let model = DeleteAccountModel(app: app)
        model.password = FakeQBankServer.maker.password
        await model.delete()
        #expect(model.problem == "QBank is still making a set in NURS 310. Wait until it is filed, or cancel it, then delete your account.")
        #expect(app.account?.email == FakeQBankServer.maker.email)
    }

    /// The fifth wrong password locks deleting, and the fake says so in its header too.
    @Test func fakeServerLocksDeletingAfterFiveWrongPasswords() async throws {
        let app = try #require(Self.launch("signed-in"))
        let model = DeleteAccountModel(app: app)
        for _ in 1...4 {
            model.password = "not-it"
            await model.delete()
            #expect(model.problem == "That password is not right.")
        }
        model.password = "not-it"
        await model.delete()
        #expect(model.problem == "Too many tries. Try again in 15 minutes.")
        #expect(model.canDelete == false)
        #expect(app.account?.email == FakeQBankServer.student.email)
    }

    @Test(arguments: [("maker", true), ("maker-not-set-up", false)])
    func makerScenariosSignInAsTheAccountThatMakesQuestions(scenario: String, isSetUp: Bool) async throws {
        let app = try #require(Self.launch(scenario))
        #expect(app.account?.email == FakeQBankServer.maker.email)
        let hub = AddModel(app: app)
        await hub.load()
        #expect(hub.canMake == isSetUp)
        #expect(hub.makeNote == (isSetUp ? "1 of 3 sets left today" : "Making questions is not set up yet."))
        #expect(hub.inProgress.count == (isSetUp ? 2 : 0))
    }

    /// Through the fake server, as the server answers: her agent's key, an agent's code in small
    /// letters and without its dash, an approval whose key is listed once the agent picks it up, a
    /// revoke that stays, and the code answered already.
    @Test func signedInScenarioPairsAnAgentAndRevokesItsKey() async throws {
        let app = try #require(Self.launch("signed-in"))
        let model = ConnectAgentModel(app: app, pickupInterval: .milliseconds(100))
        await model.load()
        #expect(model.keys?.map(\.name) == [FakeAgents.macKey.name])
        #expect(model.keys?.first?.lastUsedAt != nil, "it imported a set")

        model.code = FakeAgents.importCode.lowercased().replacingOccurrences(of: "-", with: "")
        await model.lookUp()
        guard case .found(_, let pairing) = model.stage else {
            Issue.record("no agent under the code: \(model.stage)")
            return
        }
        #expect(pairing.name == FakeAgents.importAgent)
        #expect(pairing.scopes == [.import, .read])
        #expect(pairing.scopeTexts.map(\.scope) == [.import, .read])

        await model.answer(approve: true)
        #expect(model.stage == .answered(approved: true, name: FakeAgents.importAgent))
        await model.watchForPickup()
        #expect(model.watching == nil)
        #expect(model.keys?.map(\.name) == [FakeAgents.importAgent, FakeAgents.macKey.name], "newest first, once the agent picked it up")
        #expect(model.keys?.first?.lastUsedAt == nil)

        await model.revoke(try #require(model.keys?.first))
        #expect(model.revoked == "Revoked \(FakeAgents.importAgent). It stopped working just now.")
        await model.load()
        #expect(model.keys?.map(\.isRevoked) == [true, false], "the server keeps it revoked, in its place")

        model.code = FakeAgents.importCode
        await model.lookUp()
        #expect(model.stage == .answered(approved: true, name: FakeAgents.importAgent))
        #expect(model.problem == "No agent is waiting under that code. Codes last 10 minutes: ask the agent for its new one.", "answered already")
    }

    @Test func fakeServerDeniesAnAgentWithoutMakingAKey() async throws {
        let app = try #require(Self.launch("signed-in"))
        let pairing = try await app.client.agentPairing(code: FakeAgents.manageCode)
        #expect(pairing.name == FakeAgents.manageAgent)
        #expect(pairing.scopes == [.import, .manage])
        #expect(try await app.client.denyAgentPairing(code: FakeAgents.manageCode).status == .denied)
        try await Task.sleep(for: .seconds(FakeAgents.pickupDelay))
        #expect(try await app.client.agentKeys().map(\.name) == [FakeAgents.macKey.name])
    }

    /// Five codes that match nothing lock her answers for 15 minutes, the right code included.
    @Test func fakeServerLocksAgentCodesAfterFiveThatMatchNothing() async throws {
        let app = try #require(Self.launch("signed-in"))
        for _ in 1...4 {
            let error = await #expect(throws: QBankError.self) { _ = try await app.client.agentPairing(code: "ZZZZ-ZZZZ") }
            #expect(error?.serverCode == .pairingNotFound)
        }
        let fifth = await #expect(throws: QBankError.self) { _ = try await app.client.agentPairing(code: "ZZZZ-ZZZZ") }
        #expect(fifth == .server(ServerError(status: 429, code: .tooManyAttempts, message: "Too many tries. Try again in 15 minutes.", retryAfterSeconds: 900)))
        let right = await #expect(throws: QBankError.self) { _ = try await app.client.agentPairing(code: FakeAgents.importCode) }
        #expect(right?.serverCode == .tooManyAttempts)
    }

    @Test func fakeServerSaysWhichSetHerAgentImported() async throws {
        let app = try #require(Self.launch("signed-in"))
        let sets = try await app.client.course(id: FakeQBankServer.mentalHealthID).folders.flatMap(\.sets)
        #expect(sets.filter { $0.importedByAgent != nil }.map(\.id) == [FakeAgents.importedSetID])
        #expect(sets.first { $0.id == FakeAgents.importedSetID }?.importedByAgent == ImportingAgent(id: FakeAgents.macKey.id, name: FakeAgents.macKey.name))
    }

    @Test func fakeServerSignsInAndRefusesWrongPasswords() async throws {
        let app = try #require(Self.launch("signed-out"))
        let model = SignInModel(app: app)
        model.email = FakeQBankServer.student.email
        model.password = "wrong"
        await model.signIn()
        #expect(model.problem == "That email or password is not right.")
        model.password = FakeQBankServer.student.password
        await model.signIn()
        #expect(app.route == .signedIn(app.account!))
    }

    @Test func fakeServerSignsUpTheListedEmailOnce() async throws {
        let app = try #require(Self.launch("signed-out"))
        let short = SignUpModel(app: app)
        short.email = FakeQBankServer.signUpEmail
        short.password = "short"
        await short.signUp()
        #expect(short.problem == "Choose a password of at least 8 characters.")

        let model = SignUpModel(app: app)
        model.email = " New.User@example.com "
        model.password = "synthetic-pass-9"
        await model.signUp()
        #expect(model.problem == nil)
        #expect(app.account?.email == FakeQBankServer.signUpEmail)
        #expect(app.route == .signedIn(app.account!))

        // The account it made signs in with that password, and cannot sign up again.
        await app.signOut()
        let again = SignUpModel(app: app)
        again.email = FakeQBankServer.signUpEmail
        again.password = "synthetic-pass-9"
        await again.signUp()
        #expect(again.problem?.hasPrefix("This email can't sign up here.") == true)
        let signIn = SignInModel(app: app)
        signIn.email = FakeQBankServer.signUpEmail
        signIn.password = "synthetic-pass-9"
        await signIn.signIn()
        #expect(app.account?.email == FakeQBankServer.signUpEmail)
    }

    @Test func fakeServerLocksAnEmailsSignUpAfterFiveRefusals() async throws {
        let app = try #require(Self.launch("signed-out"))
        let model = SignUpModel(app: app)
        model.email = "stranger@example.com"
        var problems: [String?] = []
        for _ in 0..<6 {
            // A refusal empties the password, as she would type it again.
            model.password = "synthetic-pass-9"
            await model.signUp()
            problems.append(model.problem)
        }
        let refused = "This email can't sign up here. If you already have an account, sign in. Otherwise, ask the owner to add your email."
        let locked = "Too many tries. Try again in 15 minutes."
        #expect(problems == [refused, refused, refused, refused, locked, locked])

        // The lock is that email's sign-up only.
        model.email = FakeQBankServer.signUpEmail
        model.password = "synthetic-pass-9"
        await model.signUp()
        #expect(app.account?.email == FakeQBankServer.signUpEmail)
    }

    @Test func fakeServerRestoresOnce() async throws {
        let app = try #require(Self.launch("signed-in"))
        let course = CourseModel(app: app, id: FakeQBankServer.mentalHealthID)
        await course.load()
        let replaced = try #require(course.folder(FakeStudy.week2)?.sets.last)
        #expect(replaced.status == .replaced)
        await course.restore(replaced)
        #expect(course.folder(FakeStudy.week2)?.sets.last?.status == .restored, "the restored version stays in its folder")
        #expect(course.problem == nil)
    }

    @Test func fakeServerEditsTheCatalogAsTheServerDoes() async throws {
        let app = try #require(Self.launch("signed-in"))
        let home = HomeModel(app: app)
        await home.load()
        #expect(home.nextSemesterNumber == 3)
        await home.addSemester()
        #expect(home.semesters?.map(\.name) == ["Semester 1", "Semester 2", "Semester 3"])
        #expect(home.nextSemesterNumber == nil)

        let semester = SemesterModel(catalog: CatalogModel(app: app, catalog: home.catalog), id: FakeQBankServer.semester2ID)
        semester.newCode = "nurs 310"
        semester.newTitle = "Pediatrics"
        #expect(await semester.addCourse()?.code == "nurs 310")
        #expect(semester.addProblem == nil)
        await home.load()

        func mentalHealth() throws -> CourseSummary {
            try #require(home.catalog?.course(id: FakeQBankServer.mentalHealthID))
        }
        let second = try #require(home.semesters?.first { $0.id == FakeQBankServer.semester2ID })
        #expect(home.otherSemesters(than: try mentalHealth()).map(\.number) == [2, 3])
        await home.move(try mentalHealth(), to: second)
        #expect(home.editProblem == "This semester already has a course with the code NURS 310.")
        let course = CourseEditModel(catalog: CatalogModel(app: app, catalog: home.catalog), id: FakeQBankServer.mentalHealthID)
        course.code = "NURS 311"
        await course.save()
        #expect(course.problem == nil)
        await home.load()
        await home.move(try mentalHealth(), to: second)
        #expect(home.editProblem == nil)
        #expect(home.courses(in: try #require(home.semesters?.first { $0.id == FakeQBankServer.semester2ID })).map(\.code) == ["nurs 310", "NURS 311"])
        await home.setArchived(try mentalHealth(), true)
        #expect(try mentalHealth().archivedAt != nil)
        #expect(home.courses(in: try #require(home.semesters?.first { $0.id == FakeQBankServer.semester2ID })).map(\.code) == ["nurs 310"])
        let detail = CourseModel(app: app, id: FakeQBankServer.mentalHealthID)
        await detail.load()
        #expect(detail.course?.code == "NURS 311")
        #expect(detail.course?.semester?.number == 2)
    }

    @Test func fakeServerRefusesPasswordsAsTheServerDoes() async throws {
        let app = try #require(Self.launch("signed-in"))
        let wrong = await #expect(throws: QBankError.self) {
            try await app.client.changePassword(current: "not-it", new: "synthetic-pass-9")
        }
        #expect(wrong?.serverCode == .invalidCredentials)
        let same = await #expect(throws: QBankError.self) {
            try await app.client.changePassword(current: FakeQBankServer.student.password, new: FakeQBankServer.student.password)
        }
        #expect(same?.serverCode == .samePassword)
        let short = await #expect(throws: QBankError.self) {
            try await app.client.changePassword(current: FakeQBankServer.student.password, new: "short")
        }
        #expect(short?.serverCode == .invalidRequest)
        let changed = try await app.client.changePassword(current: FakeQBankServer.student.password, new: "synthetic-pass-9")
        #expect(changed.user.email == FakeQBankServer.student.email)
    }

    @Test func phoneSettingsStartEmptyUnlessKept() throws {
        let environment = [DebugLaunchScenario.scenarioKey: "signed-in"]
        let first = try #require(Self.launch(environment))
        #expect(first.look.look == .matchDevice)
        first.look.look = .dark
        var keep = environment
        keep[DebugLaunchScenario.keepPhoneSettingsKey] = "1"
        #expect(Self.launch(keep)?.look.look == .dark)
        #expect(Self.launch(environment)?.look.look == .matchDevice)
    }

    @Test func deviceOwnerAnswersTheLockAsTheTestSays() async throws {
        #expect(DebugLaunchScenario.deviceOwnerKind(in: [:]) == nil)
        let environment = [DebugLaunchScenario.scenarioKey: "signed-in", DebugLaunchScenario.deviceOwnerKey: "face-id-refusing"]
        let first = try #require(Self.launch(environment))
        #expect(first.lock.method == .faceID)
        #expect(!first.lock.isEnabled, "the lock starts off")
        await first.lock.turnOn()
        #expect(!first.lock.isEnabled, "refused")

        let confirming = try #require(Self.launch([DebugLaunchScenario.scenarioKey: "signed-in", DebugLaunchScenario.deviceOwnerKey: "face-id"]))
        await confirming.lock.turnOn()
        #expect(confirming.lock.isEnabled)

        var keep = environment
        keep[DebugLaunchScenario.keepPhoneSettingsKey] = "1"
        let relaunched = try #require(Self.launch(keep))
        #expect(relaunched.lock.isLocked, "the lock kept on the phone locks the next launch")
        await relaunched.becameActive()
        #expect(relaunched.lock.isLocked)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(DebugLaunchScenario.ownerConfirmsNotification as CFString), nil, nil, true
        )
        try await Task.sleep(for: .milliseconds(200))
        await relaunched.lock.unlock()
        #expect(!relaunched.lock.isLocked)

        let noPasscode = try #require(Self.launch([DebugLaunchScenario.scenarioKey: "signed-in", DebugLaunchScenario.deviceOwnerKey: "no-passcode"]))
        #expect(noPasscode.lock.method == nil)
    }

    @Test func fakeServerServesEveryFormatAndScoresWithTheServersRules() async throws {
        let app = try #require(Self.launch("signed-in"))
        let set = try await app.client.practiceSet(id: "mixed-v1")
        #expect(set.courseID == FakeQBankServer.mentalHealthID)
        #expect(set.questions.compactMap(\.type) == QuestionType.allCases)
        #expect(set.questions.allSatisfy { !$0.rationale.isEmpty && !$0.takeaway.isEmpty })
        #expect(set.questions[1].table != nil)
        #expect(set.questions[0].images.first?.placement == .rationale)

        let sata = set.questions[2]
        let submission = AttemptSubmission(clientAttemptID: "fake-1", questionID: sata.id, response: .sata(picks: [0, 1, 3]), guessed: true)
        let saved = try await app.client.recordAttempt(submission)
        #expect(saved.status == .partial)
        #expect(saved.points == 1)
        #expect(saved.maxPoints == 3)
        #expect(saved.label == "Partly correct")
        #expect(saved.inReview)
        #expect(!saved.replayed)
        #expect(try await app.client.recordAttempt(submission).replayed, "a repeated id is answered with the saved attempt")

        let course = try await app.client.course(id: FakeQBankServer.mentalHealthID)
        let mixed = try #require(course.folders.first { $0.id == FakeStudy.weeks1to3 }?.sets.first)
        #expect(mixed.answeredCount == 1)
        #expect(mixed.fullyRightCount == 0)
    }

    @Test func unknownScenarioIsRejected() {
        let environment = [DebugLaunchScenario.scenarioKey: "welcome"]
        #expect(throws: DebugLaunchScenario.UnknownScenario.self) {
            try DebugLaunchScenario.scenario(in: environment)
        }
    }

    @Test func phoneDataIsEmptiedUnlessKept() async throws {
        let folder = OfflineStoreTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let offline = [DebugLaunchScenario.scenarioKey: "signed-in", DebugLaunchScenario.networkKey: "offline"]
        let first = try #require(Self.launch(offline, folder: folder))
        let submission = AttemptSubmission(clientAttemptID: AttemptSubmission.newID(), questionID: "mixed-v1-q0", response: .single(choice: 0))
        #expect(try await first.submit(submission, courseID: FakeQBankServer.mentalHealthID) == .waiting(reason: .transport(.notConnectedToInternet)))

        var keep = offline
        keep[DebugLaunchScenario.keepPhoneDataKey] = "1"
        #expect(Self.launch(keep, folder: folder)?.offline?.waiting.map(\.id) == [submission.clientAttemptID])
        #expect(Self.launch(offline, folder: folder)?.offline?.waiting.isEmpty == true)
    }

    @Test func theNetworkCanStartOffAndTheTestTurnsItOn() async throws {
        let environment = [DebugLaunchScenario.scenarioKey: "signed-in", DebugLaunchScenario.networkKey: "offline"]
        let app = try #require(Self.launch(environment))
        #expect(!app.connection.isOnline)
        await #expect(throws: QBankError.transport(.notConnectedToInternet)) {
            _ = try await app.client.catalog()
        }

        // As a UI test does from its own process.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(DebugLaunchScenario.networkOnlineNotification as CFString), nil, nil, true)
        try await waitUntil { app.connection.isOnline }
        #expect(try await app.client.catalog().semesters.count == 2)

        CFNotificationCenterPostNotification(center, CFNotificationName(DebugLaunchScenario.networkOfflineNotification as CFString), nil, nil, true)
        try await waitUntil { !app.connection.isOnline }
    }

    @Test func theTestSetsTheLookForItsScreenshots() async throws {
        let app = try #require(Self.launch("signed-in"))
        #expect(app.look.look == .matchDevice)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for look in [Look.dark, .light, .matchDevice] {
            CFNotificationCenterPostNotification(center, CFNotificationName(DebugLaunchScenario.lookNotification(look) as CFString), nil, nil, true)
            try await waitUntil { app.look.look == look }
        }
    }

    @Test func fakeServerServesTheSetsOfBothCourses() async throws {
        let app = try #require(Self.launch("signed-in"))
        let course = try await app.client.course(id: FakeQBankServer.fundamentalsID)
        for set in course.folders.flatMap(\.sets) {
            let practice = try await app.client.practiceSet(id: set.id)
            #expect(practice.courseID == FakeQBankServer.fundamentalsID)
            #expect(practice.questions.count == set.questionCount)
        }
        let first = try #require(course.folders.first?.sets.first)
        let saved = try await app.client.recordAttempt(AttemptSubmission(questionID: first.questionIDs[0], response: .single(choice: 0)))
        #expect(saved.courseID == FakeQBankServer.fundamentalsID)
    }

    // MARK: Slice 1c: the fake server keeps the server's study rules

    @Test func fakeServerRunsAWrongQuestionsExamAsTheServerDoes() async throws {
        let app = try #require(Self.launch("signed-in"))
        let course = CourseRef(id: FakeQBankServer.mentalHealthID, code: "NURS 310", title: "Mental Health")
        let setup = ExamSetupModel(app: app, route: ExamSetupRoute(course: course))
        await setup.load()
        #expect(setup.groups.map(\.title) == ["Exam 1", "Exam 2", "On no page"])
        #expect(setup.folders.map(\.name) == ["Week 1", "Week 2", "Week 3", "Weeks 1-3"])
        #expect(setup.setup?.exams.count == 3)
        #expect(setup.setup?.exams.map(\.courseExamID) == [FakeStudy.exam1, nil, FakeStudy.exam1])
        setup.wrongOnly = true
        for folder in setup.folders.prefix(2) { setup.toggle(folder) }
        await setup.readPlan()
        #expect(setup.summaryCount == "11 questions")
        #expect(setup.summaryTime == "in 16.5 minutes")
        #expect(setup.summarySplit == "4 from Week 1 · 7 from Week 2 · Fewer than 40, so it’s all of them at 1.5 minutes each.")
        #expect(setup.setup?.courseExams.map(\.courseExamID) == [FakeStudy.exam1, FakeStudy.exam2], "a plan for each page")
        #expect(setup.setup?.courseExams.first?.preview.questionCount == 40)
        #expect(try await app.client.course(id: course.id).examTimeLimitSeconds == 3600)
        let exam = try #require(await setup.start())
        #expect(exam.questions.count == 11)
        #expect(exam.practiceWeeks == ["Week 2"])
        #expect(exam.secondsLeftAtServerNow > 16 * 60)

        // A folder with nothing wrong is refused, as the server words it.
        let wrongOnly = try await #require(throws: QBankError.self) {
            try await app.client.startExam(courseID: course.id, folderIDs: [FakeStudy.week3], pool: .wrong)
        }
        #expect(wrongOnly.serverCode == .noWrongQuestions)
        #expect(Wording.problem(wrongOnly) == "Week 3 has no wrong questions. Untick it, or turn off Wrong questions only.")
    }

    /// Her course's pages from before badges say Exam; a new page has none; the page update sets
    /// one, null clears it, and left out it stays, as the server does.
    @Test func fakeServerKeepsPageBadges() async throws {
        let app = try #require(Self.launch("signed-in"))
        let id = FakeQBankServer.mentalHealthID
        let course = try await app.client.course(id: id)
        #expect(course.exams.map(\.badge) == [.exam, .exam])
        let created = try await app.client.createCourseExam(courseID: id, name: "Page 3", folderIDs: [])
        #expect(created.badge == nil)
        let set = try await app.client.updateCourseExam(id: created.id, name: "Page 3", folderIDs: [], badge: .concept)
        #expect(set.badge == .concept)
        let kept = try await app.client.updateCourseExam(id: created.id, name: "Page 3", folderIDs: [])
        #expect(kept.badge == .concept)
        let cleared = try await app.client.updateCourseExam(id: created.id, name: "Page 3", folderIDs: [], badge: .some(nil))
        #expect(cleared.badge == nil)
        #expect(try await app.client.course(id: id).exams.map(\.badge) == [.exam, .exam, nil])
    }

    @Test func fakeServerKeepsExamPageRules() async throws {
        let app = try #require(Self.launch("signed-in"))
        let id = FakeQBankServer.mentalHealthID
        let taken = try await #require(throws: QBankError.self) {
            try await app.client.createCourseExam(courseID: id, name: "Exam 3", folderIDs: [FakeStudy.week1, FakeStudy.week2, FakeStudy.week3])
        }
        #expect(Wording.problem(taken) == "Week 1 and Week 2 are in Exam 1. Week 3 is in Exam 2.")
        let named = try await #require(throws: QBankError.self) {
            try await app.client.createCourseExam(courseID: id, name: "exam 1", folderIDs: [])
        }
        #expect(Wording.problem(named) == "This course already has an exam named exam 1.")
        let blank = try await #require(throws: QBankError.self) {
            try await app.client.createCourseExam(courseID: id, name: "  ", folderIDs: [])
        }
        #expect(Wording.problem(blank) == "Exam name is required.")
        let created = try await app.client.createCourseExam(courseID: id, name: " Exam 3 ", folderIDs: [FakeStudy.weeks1to3])
        #expect(created.name == "Exam 3")
        #expect(created.sortOrder == 3)
        #expect(created.folderIDs == [FakeStudy.weeks1to3])
        #expect(created.weekLabels == ["Weeks 1-3"])

        // A page's folders are in the order sent; one it gives up goes back under Folders.
        let reordered = try await app.client.updateCourseExam(id: FakeStudy.exam1, name: "Exam 1", folderIDs: [FakeStudy.week2, FakeStudy.week1])
        #expect(reordered.folderIDs == [FakeStudy.week2, FakeStudy.week1])
        try await app.client.createFolder(courseID: id, name: "Week 2")
        let clash = try await #require(throws: QBankError.self) {
            try await app.client.updateCourseExam(id: FakeStudy.exam1, name: "Exam 1", folderIDs: [FakeStudy.week1])
        }
        #expect(Wording.problem(clash) == "NURS 310 already has a folder named Week 2.", "her Folders list has a Week 2 already")

        // Deleting a page puts its folders under Folders, unless one's name is taken there.
        let preview = try await app.client.courseExamDeletion(id: FakeStudy.exam1)
        #expect(preview.refusal == "NURS 310 already has a folder named Week 2 in its Folders list. Rename one of them before deleting Exam 1.")
        let held = try await #require(throws: QBankError.self) { try await app.client.deleteCourseExam(id: FakeStudy.exam1, confirm: preview.confirm) }
        #expect(Wording.problem(held) == preview.refusal)
        let made = try await app.client.courseExamDeletion(id: created.id)
        #expect(made.message == "Delete Exam 3? Its folder Weeks 1-3 stays, with its sets and your progress, under Folders. You can undo this for 30 days.")
        #expect(made.warning == DeleteWarning(title: "Delete Exam 3?", body: "Its folder Weeks 1-3 stays, with its sets and your progress, under Folders. You can undo this for 30 days."))
        let unconfirmed = try await #require(throws: QBankError.self) { try await app.client.deleteCourseExam(id: created.id, confirm: "stale") }
        #expect(unconfirmed.serverCode == .deletionChanged)
        #expect(Wording.problem(unconfirmed) == "Exam 3 changed since you were warned. Look again before deleting it.")
        try await app.client.deleteCourseExam(id: created.id, confirm: made.confirm)
        let gone = try await #require(throws: QBankError.self) { _ = try await app.client.courseExamDeletion(id: created.id) }
        #expect(Wording.problem(gone) == "That exam page was deleted.")
        let course = try await app.client.course(id: id)
        #expect(course.exams.map(\.name) == ["Exam 1", "Exam 2"])
        #expect(course.folders.filter { $0.examPageID == nil }.map(\.name) == ["Week 2", "Weeks 1-3"], "its folder is under Folders, at the end")

        // Undo puts it back with its folder; a page of its name meanwhile holds it in Recently deleted.
        let back = try await app.client.undoDeleteCourseExam(id: created.id)
        #expect(back.folderIDs == [FakeStudy.weeks1to3])
        let again = try await app.client.courseExamDeletion(id: created.id)
        try await app.client.deleteCourseExam(id: created.id, confirm: again.confirm)
        _ = try await app.client.createCourseExam(courseID: id, name: "exam 3", folderIDs: [])
        let refused = try await #require(throws: QBankError.self) { _ = try await app.client.undoDeleteCourseExam(id: created.id) }
        #expect(Wording.problem(refused) == "This course already has an exam named exam 3. Rename one of them, then bring this one back.")
        let deleted = try await app.client.recentlyDeleted(courseID: id)
        #expect(deleted.examPages.map(\.name) == ["Exam 3"])
        #expect(deleted.examPages.first?.undoRefusal == Wording.problem(refused))
    }

    @Test func fakeServerKeepsFolderRules() async throws {
        let app = try #require(Self.launch("signed-in"))
        let id = FakeQBankServer.mentalHealthID
        // A name is unique in its own list only.
        let clash = try await #require(throws: QBankError.self) { try await app.client.renameFolder(id: FakeStudy.week2, name: "week 1") }
        #expect(Wording.problem(clash) == "Exam 1 already has a folder named Week 1.")
        let renamed = try await app.client.renameFolder(id: FakeStudy.weeks1to3, name: "Week 1")
        #expect(renamed.name == "Week 1")
        #expect(renamed.sets.map(\.id) == ["mixed-v1"], "a rename answers with the folder and its sets")
        let blank = try await #require(throws: QBankError.self) { try await app.client.renameFolder(id: FakeStudy.week3, name: " ") }
        #expect(Wording.problem(blank) == "Folder name is required.")

        // A new folder lands on no exam page; a moved set brings its answers.
        let unsorted = try await app.client.createFolder(courseID: id, name: "Unsorted")
        #expect(unsorted.examPageID == nil)
        let into = try await app.client.moveSet(id: "anxiety-v1", toFolder: unsorted.id)
        #expect(into.sets.map(\.id) == ["anxiety-v1"])
        let made = try await app.client.moveSet(id: "depression-v1", toNewFolder: "Hard ones")
        #expect(made.name == "Hard ones")
        let taken = try await #require(throws: QBankError.self) { try await app.client.moveSet(id: "depression-v1", toNewFolder: "hard ones") }
        #expect(Wording.problem(taken) == "NURS 310 already has a folder named Hard ones.")
        var course = try await app.client.course(id: id)
        let folders = Dictionary(uniqueKeysWithValues: course.folders.map { ($0.id, $0) })
        #expect(folders[unsorted.id]?.sets.map(\.id) == ["anxiety-v1"])
        #expect(folders[FakeStudy.week3]?.sets.isEmpty == true)
        #expect(folders[FakeStudy.week3]?.examBankCount == 31, "the exam bank stays with its folder")
        #expect(course.folders.filter { $0.examPageID == nil }.map(\.name) == ["Week 1", "Unsorted", "Hard ones"])
        #expect(course.weeks.first { $0.label == "Week 1" }?.sets.count == 2, "an older app sees same-named folders as one week")
        #expect(course.folderCount == 6)

        // Put on a page, at the end of its folders, and taken off again to the end of the Folders list.
        let placed = try await app.client.placeFolder(id: unsorted.id, onExamPage: FakeStudy.exam2)
        #expect(placed.examPageID == FakeStudy.exam2)
        let samePage = try await #require(throws: QBankError.self) { try await app.client.placeFolder(id: FakeStudy.weeks1to3, onExamPage: FakeStudy.exam1) }
        #expect(Wording.problem(samePage) == "Exam 1 already has a folder named Week 1.")
        course = try await app.client.course(id: id)
        #expect(course.exams.last?.folderIDs == [FakeStudy.week3, unsorted.id])
        try await app.client.placeFolder(id: unsorted.id, onExamPage: nil)

        // Her order, one list at a time.
        course = try await app.client.course(id: id)
        let loose = course.folders.filter { $0.examPageID == nil }.map(\.id)
        #expect(course.folders.filter { $0.examPageID == nil }.map(\.name) == ["Week 1", "Hard ones", "Unsorted"])
        let stale = try await #require(throws: QBankError.self) {
            try await app.client.setFolderOrder(courseID: id, examPageID: nil, folderIDs: Array(loose.dropFirst()))
        }
        #expect(Wording.problem(stale) == "The folders changed since this list was shown. Reload and try again.")
        let ordered = try await app.client.setFolderOrder(courseID: id, examPageID: nil, folderIDs: loose.reversed())
        #expect(ordered.map(\.name) == ["Unsorted", "Hard ones", "Week 1"])
        course = try await app.client.course(id: id)
        #expect(course.folders.filter { $0.examPageID == nil }.map(\.name) == ["Unsorted", "Hard ones", "Week 1"])

        // Terms and Review name the folder a set is in now.
        let terms = try await app.client.terms(courseID: id)
        #expect(terms.first { $0.term == "Serotonin" }?.folderName == "Hard ones")
        #expect(terms.first { $0.term == "Serotonin" }?.folderID == made.id)
        let review = try await app.client.review(courseID: id)
        #expect(review.questions.first { $0.questionID == "rights-v1-q4" }?.folderID == FakeStudy.week1)
    }

    @Test func fakeServerKeepsReviewAsTheServerDoes() async throws {
        let app = try #require(Self.launch("signed-in"))
        let id = FakeQBankServer.mentalHealthID
        let list = try await app.client.review(courseID: id)
        #expect(list.counts.all == 12)
        #expect(list.counts.missed == 6)
        #expect(list.counts.partial == 3)
        #expect(list.counts.guessed == 4)
        let times = list.questions.map(\.answeredAt)
        #expect(times == times.sorted { $0 > $1 }, "newest first")
        let practice = try await app.client.reviewPractice(courseID: id, filter: .missed)
        #expect(practice.questions.count == 6)
        #expect(practice.title == "Review")
        let right = AttemptSubmission(questionID: "rights-v1-q0", response: .single(choice: 0))
        _ = try await app.client.recordAttempt(right)
        #expect(try await app.client.review(courseID: id).counts.missed == 5, "answered fully right without guessing, it leaves")
        let unconfirmed = try await #require(throws: QBankError.self) { try await app.client.clearReview(courseID: id, confirmed: false) }
        #expect(Wording.problem(unconfirmed) == "Clear all 11 questions from this course's Review list?")
        #expect(try await app.client.clearReview(courseID: id) == 11)
        #expect(try await app.client.course(id: id).reviewCount == 0)
    }
}
