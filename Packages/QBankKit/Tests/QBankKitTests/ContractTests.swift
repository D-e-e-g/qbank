import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// Each test drives the client through one recorded exchange with the real server routes and
/// checks both directions: the request the client builds matches the recorded one, and the
/// recorded response decodes into the models.
@Suite("Contract: sign-in and session")
struct SessionContractTests {
    @Test func health() async throws {
        let transport = try FixtureTransport("health")
        let (client, _) = TestClient.make(transport, token: nil)
        let health = try await client.health()
        #expect(health.status == "ok")
        try expectRequest(transport.requests.first, matches: Fixture.load("health"))
    }

    @Test func signInStoresTheBearerToken() async throws {
        let transport = try FixtureTransport("sign-in")
        let (client, store) = TestClient.make(transport, token: nil)
        let signedIn = try await client.signIn(email: "student@example.com", password: "synthetic-pass-1")
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-in"))
        #expect(signedIn.token == "synthetic-session-token")
        #expect(signedIn.user.role == .student)
        #expect(signedIn.user.mustChangePassword == false)
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == signedIn.user)
        #expect(stored.expiresAt == signedIn.expiresAt)
    }

    @Test func wrongPasswordStoresNothing() async throws {
        let transport = try FixtureTransport("sign-in-wrong-password")
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signIn(email: "student@example.com", password: "not-the-password")
        }
        #expect(error?.serverCode == .invalidCredentials)
        #expect(error?.needsSignIn == false)
        #expect(try store.load() == nil)
    }

    @Test func lockedSignInSaysHowLong() async throws {
        let transport = try FixtureTransport("sign-in-locked")
        let (client, _) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signIn(email: "locked@example.com", password: "wrong")
        }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 429)
        #expect(server.code == .tooManyAttempts)
        #expect(server.retryAfterSeconds == 900)
        #expect(error?.isTemporary == true)
    }

    @Test func signUpMakesASignedInUserAccount() async throws {
        let transport = try FixtureTransport("sign-up")
        let (client, store) = TestClient.make(transport, token: nil)
        let signedIn = try await client.signUp(email: "new.user@example.com", password: "synthetic-pass-2")
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-up"))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(signedIn.token == "synthetic-session-token")
        #expect(signedIn.user.email == "new.user@example.com")
        #expect(signedIn.user.role == .student)
        #expect(signedIn.user.mustChangePassword == false)
        #expect(signedIn.user.palette == .dusk)
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == signedIn.user)
        #expect(stored.expiresAt == signedIn.expiresAt)
    }

    @Test func refusedSignUpStoresNothing() async throws {
        let transport = try FixtureTransport("sign-up-refused")
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signUp(email: "stranger@example.com", password: "synthetic-pass-3")
        }
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-up-refused"))
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 403)
        #expect(server.code == .signUpRefused)
        #expect(server.message == "This email can't sign up here. If you already have an account, sign in. Otherwise, ask the owner to add your email.")
        #expect(error?.needsSignIn == false)
        #expect(try store.load() == nil)
    }

    @Test func lockedSignUpSaysHowLong() async throws {
        let transport = try FixtureTransport("sign-up-locked")
        let (client, _) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signUp(email: "locked@example.com", password: "synthetic-pass-3")
        }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 429)
        #expect(server.code == .tooManyAttempts)
        #expect(server.retryAfterSeconds == 900)
        #expect(server.message == "Too many tries. Try again in 15 minutes.")
    }

    @Test func shortSignUpPasswordIsRefused() async throws {
        let transport = try FixtureTransport("sign-up-short-password")
        let (client, store) = TestClient.make(transport, token: nil)
        let error = await #expect(throws: QBankError.self) {
            try await client.signUp(email: "new.user@example.com", password: "short")
        }
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-up-short-password"))
        #expect(error?.serverCode == .invalidRequest)
        #expect(try store.load() == nil)
    }

    @Test func sessionRefreshesTheStoredAccount() async throws {
        let transport = try FixtureTransport("session")
        let (client, store) = TestClient.make(transport)
        let session = try await client.session()
        try expectRequest(transport.requests.first, matches: Fixture.load("session"))
        #expect(session.user.email == "student@example.com")
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == session.user)
    }

    @Test func endedSessionNeedsSignIn() async throws {
        let transport = try FixtureTransport("session-after-sign-out")
        let (client, _) = TestClient.make(transport, token: "synthetic-session-token-2")
        let error = await #expect(throws: QBankError.self) { try await client.session() }
        #expect(error?.needsSignIn == true)
        try expectRequest(transport.requests.first, matches: Fixture.load("session-after-sign-out"))
    }

    @Test func changePasswordStoresTheNewToken() async throws {
        let transport = try FixtureTransport("change-password")
        let (client, store) = TestClient.make(transport)
        let signedIn = try await client.changePassword(current: "synthetic-pass-1", new: "synthetic-pass-3")
        try expectRequest(transport.requests.first, matches: Fixture.load("change-password"))
        #expect(signedIn.token == "synthetic-session-token-2")
        #expect(try store.load()?.token == "synthetic-session-token-2")
    }

    @Test func wrongCurrentPasswordKeepsTheSession() async throws {
        let transport = try FixtureTransport("change-password-wrong")
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.changePassword(current: "not-it", new: "synthetic-pass-3")
        }
        #expect(error?.serverCode == .invalidCredentials)
        #expect(error?.needsSignIn == false)
        #expect(try store.load()?.token == "synthetic-session-token")
        try expectRequest(transport.requests.first, matches: Fixture.load("change-password-wrong"))
    }

    @Test(arguments: [
        ("change-password-same", ServerError.Code.samePassword),
        ("change-password-short", ServerError.Code.invalidRequest),
    ])
    func refusedNewPasswordKeepsTheSession(name: String, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, store) = TestClient.make(transport)
        let current = try #require(fixture.request.body?["currentPassword"]?.stringValue)
        let new = try #require(fixture.request.body?["newPassword"]?.stringValue)
        let error = await #expect(throws: QBankError.self) {
            try await client.changePassword(current: current, new: new)
        }
        #expect(error?.serverCode == code)
        #expect(error?.needsSignIn == false)
        #expect(try store.load()?.token == "synthetic-session-token")
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func signOutEndsTheSessionHereAndThere() async throws {
        let transport = try FixtureTransport("sign-out")
        let (client, store) = TestClient.make(transport, token: "synthetic-session-token-2")
        try await client.signOut()
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-out"))
        #expect(try store.load() == nil)
    }

    /// Signed in on two devices, she signs out everywhere from one: it forgets its session, and the
    /// other device's next call needs sign-in.
    @Test func signOutEverywhereEndsEverySession() async throws {
        let transport = try FixtureTransport("sign-out-everywhere")
        let (client, store) = TestClient.make(transport)
        try await client.signOutEverywhere()
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-out-everywhere"))
        #expect(try store.load() == nil)

        let other = try FixtureTransport("session-after-sign-out-everywhere")
        let (laptop, _) = TestClient.make(other, token: "synthetic-session-token-2")
        let error = await #expect(throws: QBankError.self) { try await laptop.session() }
        #expect(error?.needsSignIn == true)
        try expectRequest(other.requests.first, matches: Fixture.load("session-after-sign-out-everywhere"))
    }

    /// From a session that had already ended, the server ends nothing; the session is left for the
    /// app to clear, as any ended one.
    @Test func signOutEverywhereFromAnEndedSessionNeedsSignIn() async throws {
        let transport = try FixtureTransport("sign-out-everywhere-signed-out")
        let (client, store) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.signOutEverywhere() }
        #expect(error?.needsSignIn == true)
        #expect(try store.load()?.token == "synthetic-session-token")
        try expectRequest(transport.requests.first, matches: Fixture.load("sign-out-everywhere-signed-out"))
    }

    @Test func pickingAPaletteKeepsTheAccountItReturns() async throws {
        let transport = try FixtureTransport("palette")
        let (client, store) = TestClient.make(transport)
        let account = try await client.setPalette(.slate)
        try expectRequest(transport.requests.first, matches: Fixture.load("palette"))
        #expect(account.palette == .slate)
        #expect(account.email == "student@example.com")
        let stored = try #require(try store.load())
        #expect(stored.token == "synthetic-session-token")
        #expect(stored.account == account)
    }

    @Test func sessionCarriesThePalette() async throws {
        let transport = try FixtureTransport("session-slate")
        let (client, store) = TestClient.make(transport)
        let session = try await client.session()
        try expectRequest(transport.requests.first, matches: Fixture.load("session-slate"))
        #expect(session.user.palette == .slate)
        #expect(try store.load()?.account?.palette == .slate)
    }

    @Test func sessionFromBeforePalettesIsDusk() async throws {
        let transport = try FixtureTransport("session")
        let (client, _) = TestClient.make(transport)
        #expect(try await client.session().user.palette == .dusk)
    }
}

@Suite("Contract: courses and practice")
struct ContentContractTests {
    @Test func semesters() async throws {
        let transport = try FixtureTransport("semesters")
        let (client, _) = TestClient.make(transport)
        let semesters = try await client.catalog().semesters
        try expectRequest(transport.requests.first, matches: Fixture.load("semesters"))
        let course = try #require(semesters.first?.courses.first)
        #expect(semesters.first?.number == 1)
        #expect(semesters.first?.startsOn == nil)
        #expect(course.code == "NURS 101")
        #expect(course.questionCount == 10)
        #expect(course.weekCount == 2)
        #expect(course.folderCount == 2)
        #expect(course.archivedAt == nil)
    }

    @Test func course() async throws {
        let fixture = try Fixture.load("course")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let course = try await client.course(id: id)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(course.id == id)
        #expect(course.weeks.map(\.label) == ["Week 1", "Week 2"])
        #expect(course.weeks.map(\.examBankCount) == [2, 0])
        #expect(course.examQuestionCount == 4)
        #expect(course.examTimeLimitSeconds == 360, "the server's time for an exam over every folder")
        let set = try #require(course.weeks.first?.sets.first)
        #expect(set.questionIDs.count == 8)
        #expect(set.status == .imported)
        #expect(set.lastAnsweredAt == nil)
        let importedAt = try #require(fixture.response.body["weeks"]?.arrayValue?.first?["sets"]?.arrayValue?.first?["importedAt"]?.stringValue)
        #expect(QBankJSON.formatDate(set.importedAt) == importedAt)
        #expect(course.exams.isEmpty, "a course has no exams until one is made")
        #expect(course.folders.map(\.name) == ["Week 1", "Week 2"], "day one: a folder for each week, in week order")
        #expect(course.folders.allSatisfy { $0.examPageID == nil })
        #expect(course.folders.map(\.examBankCount) == [2, 0])
        #expect(course.folders.first?.sets == course.weeks.first?.sets)
        #expect(course.folderCount == 2)
    }

    @Test func missingCourse() async throws {
        let fixture = try Fixture.load("course-not-found")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.course(id: "00000000-0000-4000-8000-000000000000")
        }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error")
            return
        }
        #expect(server.status == 404)
        #expect(server.code == .requestRefused)
        #expect(server.message == "That course is not in the app.")
    }

    @Test func terms() async throws {
        let fixture = try Fixture.load("terms")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let terms = try await client.terms(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(terms.map(\.term) == ["Tachycardia"])
        #expect(terms.first?.weekLabel == "Week 1")
        #expect(terms.first?.folderName == "Week 1")
        #expect(terms.first?.folderID == fixture.response.body["terms"]?.arrayValue?.first?["folderId"]?.stringValue)
        #expect(terms.first?.folderID != nil)
    }

    @Test func practiceSetReadsEveryFormat() async throws {
        let fixture = try Fixture.load("practice-set")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let set = try await client.practiceSet(id: id)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(set.kind == .practice)
        #expect(set.weekLabel == "Week 1")
        #expect(set.folderID != nil)
        #expect(set.questions.compactMap(\.type) == QuestionType.allCases)
        #expect(set.questions.map(\.publicID) == ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q7", "Q8"])

        let single = set.questions[0]
        #expect(single.clinicalJudgmentStep == "Analyze cues")
        #expect(single.terms == [QuestionTerm(key: "tachy", term: "Tachycardia", meaning: "An invented definition of a fast heart rate.")])
        #expect(single.body == .single(options: [
            QuestionOption(text: "The useful action", isCorrect: true, why: "It addresses the finding."),
            QuestionOption(text: "A distractor", isCorrect: false, why: "It does not change the finding."),
            QuestionOption(text: "Another distractor", isCorrect: false, why: "Neither does this."),
        ]))
        #expect(single.table == QuestionTable(caption: "Invented readings", head: ["Time", "HR", ""], rows: [["0900", "82", ""], ["0915", "94", "extra"]]))
        #expect(single.images.isEmpty)

        let priority = set.questions[1]
        #expect(priority.images.count == 2)
        #expect(priority.images.first?.placement == .stem)
        #expect(priority.images.first?.caption == "Invented caption")
        #expect(priority.images.first?.file?.mediaType == "image/png")
        #expect(priority.images.last?.placement == .rationale)
        if case .svg(let markup)? = priority.images.last?.source {
            #expect(markup.hasPrefix("<svg"))
        } else {
            Issue.record("Expected SVG markup")
        }

        #expect(set.questions[3].body == .highlight(segments: [
            QuestionOption(text: "The client is alert.", isCorrect: false, why: "Expected."),
            QuestionOption(text: "Heart rate 128.", isCorrect: true, why: "Too fast."),
            QuestionOption(text: "Skin is cool and clammy.", isCorrect: true, why: "Poor perfusion."),
            QuestionOption(text: "Ate breakfast.", isCorrect: false, why: "Expected."),
        ]))
        #expect(set.questions[4].body == .order(items: [OrderItem(text: "Step one", why: "First."), OrderItem(text: "Step two"), OrderItem(text: "Step three")]))
        #expect(set.questions[5].body == .match(
            pairs: [MatchPair(left: "Drug A", right: "Class A", why: "A goes with A."), MatchPair(left: "Drug B", right: "Class B")],
            extra: [MatchExtra(right: "Class C", why: "Matches nothing.")]
        ))
        #expect(set.questions[6].body == .matrix(
            columns: ["Indicated", "Not indicated"],
            rows: [MatrixRow(text: "Order one", answer: "Indicated", why: "Helps."), MatrixRow(text: "Order two", answer: "Not indicated")]
        ))
        #expect(set.questions[7].body == .cloze(Cloze(
            text: "The client is most at risk for {0} because of {1}.",
            blanks: [ClozeBlank(options: ["bleeding", "infection", "falls"], answer: 1, why: "Invented reason."), ClozeBlank(options: ["the wound", "the diet"], answer: 0)]
        )))
    }

    @Test func restoreBringsBackThePreviousVersion() async throws {
        let fixture = try Fixture.load("practice-set-restore")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let replacedID = fixture.request.path.split(separator: "/").dropLast().last.map(String.init)!
        let restored = try await client.restorePracticeSet(id: replacedID)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(restored.id != replacedID)
        #expect(restored.status == .restored)
        #expect(restored.canRestore)
        #expect(restored.questionCount == 2)
    }

    @Test func restoringAnOldVersionIsRefused() async throws {
        let fixture = try Fixture.load("practice-set-restore-not-current")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = fixture.request.path.split(separator: "/").dropLast().last.map(String.init)!
        let error = await #expect(throws: QBankError.self) { try await client.restorePracticeSet(id: id) }
        #expect(error?.serverCode == .requestRefused)
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error")
            return
        }
        #expect(server.status == 404)
        #expect(server.message == "That set is not the current version.")
    }

    @Test func practiceSetSurvivesTheCacheRoundTrip() throws {
        let set = try Fixture.load("practice-set").decodeBody(PracticeSet.self)
        let again = try QBankJSON.decoder.decode(PracticeSet.self, from: QBankJSON.encoder.encode(set))
        #expect(again == set)
        // The copy leaves out the server's `sitting: null`, which reads back the same.
        guard case .object(var original) = try Fixture.load("practice-set").response.body else {
            Issue.record("Expected an object")
            return
        }
        #expect(original.removeValue(forKey: "sitting") == .null)
        #expect(try JSONDecoder().decode(JSONValue.self, from: QBankJSON.encoder.encode(set)) == .object(original))
    }
}

@Suite("Contract: answers")
struct AttemptContractTests {
    /// The questions the attempt fixtures answered, from the same recording.
    static func questions() throws -> [String: Question] {
        let set = try Fixture.load("practice-set").decodeBody(PracticeSet.self)
        return Dictionary(uniqueKeysWithValues: set.questions.map { ($0.id, $0) })
    }

    static let practiceAttempts = [
        "attempt-saved", "attempt-partial", "attempt-guessed", "attempt-highlight",
        "attempt-order", "attempt-match", "attempt-matrix", "attempt-cloze",
    ]

    @Test(arguments: practiceAttempts)
    func sendsTheAnswerAndReadsTheReceipt(name: String) async throws {
        let fixture = try Fixture.load(name)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let saved = try await client.recordAttempt(submission)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(saved.clientAttemptID == submission.clientAttemptID)
        #expect(saved.questionID == submission.questionID)
        #expect(saved.replayed == false)
        #expect(fixture.response.status == 201)
    }

    /// The phone's scoring gives the mark the server gave, for every format.
    @Test(arguments: practiceAttempts + ["exam-attempt"])
    func phoneScoringMatchesTheServer(name: String) throws {
        let fixture = try Fixture.load(name)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let saved = try fixture.decodeBody(SavedAttempt.self)
        let question: Question
        if name == "exam-attempt" {
            let exam = try Fixture.load("exam-start").decodeBody(Exam.self)
            question = try #require(exam.questions.first { $0.id == submission.questionID })
        } else {
            question = try #require(try Self.questions()[submission.questionID])
        }
        let score = try Scoring.score(question.body, response: submission.response)
        #expect(score.points == saved.points)
        #expect(score.maxPoints == saved.maxPoints)
        #expect(score.status == saved.status)
        // The words the phone shows while an answer waits are the ones the server sends once it has it.
        let phone = Feedback(phone: score, type: question.type)
        #expect(phone.label == saved.label)
        #expect(phone.pointsText == saved.pointsText)
        #expect(phone.ruleText == saved.ruleText)
        if name != "exam-attempt" {
            #expect(score.staysInReview(guessed: submission.guessed) == saved.inReview)
        }
    }

    @Test func replayReturnsTheSavedAttempt() async throws {
        let fixture = try Fixture.load("attempt-replayed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let saved = try await client.recordAttempt(submission)
        #expect(fixture.response.status == 200)
        #expect(saved.replayed == true)
        #expect(saved == SavedAttempt.replayOf(try Fixture.load("attempt-saved").decodeBody(SavedAttempt.self)))
    }

    @Test(arguments: [
        ("attempt-conflict", 409, ServerError.Code.attemptConflict),
        ("attempt-invalid", 400, .invalidResponse),
        ("exam-attempt-again", 409, .alreadyAnswered),
        ("exam-attempt-after-end", 409, .examFinished),
    ])
    func refusedAnswers(name: String, status: Int, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        let error = await #expect(throws: QBankError.self) { try await client.recordAttempt(submission) }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error")
            return
        }
        #expect(server.status == status)
        #expect(server.code == code)
        #expect(error?.isTemporary == false)
        let refusal = try #require(error)
        #expect(AttemptQueue.keepsWaiting(after: refusal) == false)
        try expectRequest(transport.requests.first, matches: fixture)
    }
}

@Suite("Contract: Review")
struct ReviewContractTests {
    @Test func reviewList() async throws {
        let fixture = try Fixture.load("review")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let list = try await client.review(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(list.filter == .all)
        #expect(list.counts == ReviewList.Counts(all: 7, missed: 2, partial: 4, guessed: 1))
        #expect(list.questions.count == 7)
        #expect(list.questions.allSatisfy { $0.folderName == "Week 1" && $0.folderID != nil })
    }

    @Test func filteredReviewList() async throws {
        let fixture = try Fixture.load("review-guessed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let list = try await client.review(courseID: courseID(of: fixture), filter: .guessed)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(list.filter == .guessed)
        #expect(list.questions.allSatisfy { $0.guessed })
    }

    @Test func reviewPractice() async throws {
        let fixture = try Fixture.load("review-practice")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let set = try await client.reviewPractice(courseID: courseID(of: fixture), filter: .missed)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(set.id == set.courseID)
        #expect(set.questions.count == 2)
    }

    @Test func reviewPracticeOneQuestion() async throws {
        let fixture = try Fixture.load("review-practice-one")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let questionID = try #require(fixture.request.query["question"])
        let set = try await client.reviewPractice(courseID: courseID(of: fixture), questionID: questionID)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(set.questions.map(\.id) == [questionID])
    }

    @Test func clearNeedsConfirmation() async throws {
        let fixture = try Fixture.load("review-clear-unconfirmed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.clearReview(courseID: courseID(of: fixture), confirmed: false)
        }
        #expect(error?.serverCode == .confirmationRequired)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func clear() async throws {
        let fixture = try Fixture.load("review-clear")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let cleared = try await client.clearReview(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(cleared == 7)
    }
}

@Suite("Contract: exams")
struct ExamContractTests {
    @Test func setupShowsWrongCountsPerWeek() async throws {
        let fixture = try Fixture.load("exam-setup")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let setup = try await client.examSetup(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(setup.weeks.map(\.label) == ["Week 1", "Week 2"])
        #expect(setup.weeks.map(\.source) == [.exam, .practice])
        #expect(setup.weeks.map(\.wrongCount) == [1, 0])
        #expect(setup.inProgress == nil)
        #expect(setup.exams.isEmpty)
    }

    @Test func setupCarriesTheServersRules() throws {
        let setup = try Fixture.load("exam-setup").decodeBody(ExamSetup.self)
        #expect(setup.rules == ExamRules(maxQuestions: 40, fullTimeSeconds: 3600, secondsPerQuestion: 90))
        #expect(setup.preview == nil, "read without folders")
        #expect(setup.courseExams.isEmpty, "the course has no exam pages")
    }

    /// With folders, the setup is read for the server's plan over them, from the pool asked for.
    @Test func setupAsksForThePlanOverTheTickedFolders() async throws {
        guard case .object(var body) = try Fixture.load("exam-setup-course-exams").response.body,
              case .array(let pages)? = body["courseExams"], case .object(let page)? = pages.first else {
            Issue.record("The exam setup fixture has no exam page plans")
            return
        }
        body["preview"] = page["preview"]
        let transport = FixtureTransport(status: 200, body: String(decoding: try JSONEncoder().encode(JSONValue.object(body)), as: UTF8.self))
        let (client, _) = TestClient.make(transport)
        let setup = try await client.examSetup(courseID: "c1", folderIDs: [FolderContractTests.week1, FolderContractTests.week2], pool: .wrong)
        let url = try #require(transport.requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/courses/c1/exams")
        #expect(components.query == "folderIds=\(FolderContractTests.week1)&folderIds=\(FolderContractTests.week2)&pool=wrong")
        let plan = try #require(setup.preview)
        #expect(plan.folders.map(\.drawn) == [3, 2])
        #expect(plan.questionCount == 5)
        #expect(plan.timeLimitSeconds == 450)
        #expect(plan.practiceWeeks == nil)
    }

    @Test func setupWithARunningExam() throws {
        let setup = try Fixture.load("exam-setup-in-progress").decodeBody(ExamSetup.self)
        let running = try #require(setup.inProgress)
        #expect(running.finishedAt == nil)
        #expect(running.endReason == nil)
        #expect(running.fullyRight == nil)
        #expect(running.pool == .all)
        #expect(running.practiceWeeks == ["Week 2"])
        #expect(running.courseExamID == nil, "the course has no exams")
    }

    @Test func setupAfterExams() throws {
        let setup = try Fixture.load("exam-setup-after").decodeBody(ExamSetup.self)
        #expect(setup.exams.count == 1)
        #expect(setup.exams.first?.endReason == .finished)
        #expect(setup.inProgress?.pool == .wrong)
    }

    @Test func startOverEveryQuestion() async throws {
        let fixture = try Fixture.load("exam-start")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let folders = folderIDs(of: fixture)
        let exam = try await client.startExam(courseID: courseID(of: fixture), folderIDs: folders, pool: .all)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(folders.count == 2, "Week 1 and Week 2")
        #expect(exam.isRunning)
        #expect(exam.result == nil)
        #expect(exam.questions.count == 4)
        #expect(exam.questions.allSatisfy { $0.weekLabel != nil })
        #expect(exam.timeLimitSeconds == 360)
        #expect(exam.secondsLeftAtServerNow > 0)
    }

    @Test func startOverWrongQuestions() async throws {
        let fixture = try Fixture.load("exam-start-wrong")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let exam = try await client.startExam(courseID: courseID(of: fixture), folderIDs: folderIDs(of: fixture), pool: .wrong)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.pool == .wrong)
        #expect(exam.weeks == ["Week 1"])
    }

    @Test func weekWithoutWrongQuestionsIsRefused() async throws {
        let fixture = try Fixture.load("exam-start-no-wrong")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.startExam(courseID: courseID(of: fixture), folderIDs: folderIDs(of: fixture), pool: .wrong)
        }
        #expect(error?.serverCode == .noWrongQuestions)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func examAnswerNamesItsExam() async throws {
        let fixture = try Fixture.load("exam-attempt")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let submission = try #require(fixture.request.body).decode(AttemptSubmission.self)
        #expect(submission.studySessionID != nil)
        _ = try await client.recordAttempt(submission)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func runningExam() async throws {
        let fixture = try Fixture.load("exam-running")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let exam = try await client.exam(id: id)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.answeredQuestionIDs.count == 1)
        #expect(exam.isRunning)
    }

    @Test func finishScoresTheExam() async throws {
        let fixture = try Fixture.load("exam-finish")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").dropLast().last!)
        let exam = try await client.finishExam(id: id, reason: .finished)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.endReason == .finished)
        #expect(exam.isRunning == false)
        #expect(exam.result != nil)
    }

    @Test func endedExamResult() throws {
        let exam = try Fixture.load("exam-ended").decodeBody(Exam.self)
        let result = try #require(exam.result)
        #expect(result.questionCount == 4)
        #expect(result.answered == 1)
        #expect(result.unanswered == 3)
        #expect(result.byWeek.map(\.label) == ["Week 1", "Week 2"])
        #expect(result.byFolder?.map(\.label) == ["Week 1", "Week 2"], "by the folder each question's set is in now")
        #expect(result.byFolder?.map(\.id) == exam.folderIDs, "a row is its folder, as two folders may share a name")
        #expect(result.byWeek.map(\.id) == ["Week 1", "Week 2"])
        #expect(exam.folderIDs?.count == 2)
        #expect(result.byStep.map(\.label) == ["Analyze cues"])
        let answered = try #require(result.items.first { $0.status != .unanswered })
        #expect(answered.questionID == exam.answeredQuestionIDs.first)
        #expect(answered.status == .correct)
        #expect(answered.label == "Correct")
        #expect(answered.response == .single(choice: 0))
        #expect(answered.shuffle == .options(order: [0, 2, 1]))
        let unanswered = result.items.filter { $0.questionID != answered.questionID }
        #expect(unanswered.count == 3)
        #expect(unanswered.allSatisfy { $0.status == .unanswered && $0.label == "Not answered" && $0.response == nil && $0.shuffle == nil })
    }
}

@Suite("Contract: settings")
struct SettingsContractTests {
    @Test func emptyStudyPlace() async throws {
        let transport = try FixtureTransport("place-empty")
        let (client, _) = TestClient.make(transport)
        #expect(try await client.studyPlace() == nil)
        try expectRequest(transport.requests.first, matches: Fixture.load("place-empty"))
    }

    @Test func studyPlace() async throws {
        let fixture = try Fixture.load("place")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let place = try await client.studyPlace()
        #expect(place == fixture.response.body["courseId"]?.stringValue)
        #expect(place != nil)
    }

    @Test func setStudyPlace() async throws {
        let fixture = try Fixture.load("place-put")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let courseID = try #require(fixture.request.body?["courseId"]?.stringValue)
        try await client.setStudyPlace(courseID: courseID)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func exportIsTheFileAsSent() async throws {
        let fixture = try Fixture.load("export")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let data = try await client.exportProgress()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == fixture.response.body)
    }
}

@Suite("Contract: semesters and courses")
struct CatalogContractTests {
    @Test func addSemester() async throws {
        let transport = try FixtureTransport("semester-create")
        let (client, _) = TestClient.make(transport)
        let semester = try await client.addSemester(number: 1)
        try expectRequest(transport.requests.first, matches: Fixture.load("semester-create"))
        #expect(semester.number == 1)
        #expect(semester.name == "Semester 1")
        #expect(semester.courses.isEmpty)
    }

    @Test func updateSemesterSendsAClearedDateAsNull() async throws {
        let fixture = try Fixture.load("semester-update")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let semester = try await client.updateSemester(id: id, name: "Fall 2026", startsOn: "2026-09-01", endsOn: nil)
        try expectRequest(transport.requests.first, matches: fixture)
        let body = try #require(transport.requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains(#""endsOn":null"#))
        #expect(semester.name == "Fall 2026")
        #expect(semester.startsOn == "2026-09-01")
        #expect(semester.endsOn == nil)
    }

    @Test func addCourse() async throws {
        let fixture = try Fixture.load("course-create")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let semesterID = try #require(fixture.request.body?["semesterId"]?.stringValue)
        let course = try await client.addCourse(semesterID: semesterID, code: "NURS 101", title: "Invented Basics")
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(course.code == "NURS 101")
        #expect(course.archivedAt == nil)
        #expect(course.questionCount == 0)
    }

    @Test func updateCourseRenamesAndMoves() async throws {
        let fixture = try Fixture.load("course-update")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let semesterID = try #require(fixture.request.body?["semesterId"]?.stringValue)
        let course = try await client.updateCourse(id: id, code: "NURS 111", title: "Invented Basics II", semesterID: semesterID)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(course.code == "NURS 111")
        #expect(course.title == "Invented Basics II")
    }

    @Test func archiveSendsOnlyTheFlag() async throws {
        let fixture = try Fixture.load("course-archive")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = String(fixture.request.path.split(separator: "/").last!)
        let course = try await client.setCourseArchived(id: id, true)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(course.archivedAt != nil)
    }

    @Test func editedCatalogDecodes() throws {
        let semesters = try Fixture.load("semesters-edited").decodeBody(Catalog.self).semesters
        #expect(semesters.map(\.name) == ["Fall 2026", "Semester 2"])
        #expect(semesters[0].courses.map(\.code) == ["NURS 102"])
        #expect(semesters[1].courses.first?.archivedAt != nil)
    }

    @Test(arguments: [
        ("semester-create-taken", 409, "Semester 1 already exists."),
        ("semester-create-out-of-range", 400, "A semester is 1, 2, or 3."),
        ("semester-update-blank", 400, "Semester name is required."),
        ("course-create-taken", 409, "This semester already has a course with the code nurs 101."),
        ("course-update-blank", 400, "Course name is required."),
    ])
    func refusalsCarryAMessageForHer(name: String, status: Int, message: String) throws {
        let fixture = try Fixture.load(name)
        let response = HTTPURLResponse(url: TestClient.baseURL, statusCode: fixture.response.status, httpVersion: nil, headerFields: nil)!
        let error = QBankClient.failure(status: fixture.response.status, data: try fixture.responseData, response: response)
        #expect(error == .server(ServerError(status: status, code: .requestRefused, message: message)))
        #expect(error.isTemporary == false)
        #expect(error.needsSignIn == false)
    }
}

@Suite("Contract: exam pages and folders")
struct FolderContractTests {
    static let week1 = "f0000000-0000-4000-8000-000000000001"
    static let week2 = "f0000000-0000-4000-8000-000000000002"
    static let week3 = "f0000000-0000-4000-8000-000000000003"
    static let firstPass = "f0000000-0000-4000-8000-000000000011"
    static let secondPass = "f0000000-0000-4000-8000-000000000012"
    static let examOne = "ce000000-0000-4000-8000-000000000001"
    static let examTwo = "ce000000-0000-4000-8000-000000000002"

    @Test func createSendsTheNameAndFolders() async throws {
        let fixture = try Fixture.load("course-exam-create")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let exam = try await client.createCourseExam(courseID: courseID(of: fixture), name: "Exam 1", folderIDs: [Self.week1, Self.week2])
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.id == Self.examOne)
        #expect(exam.name == "Exam 1")
        #expect(exam.sortOrder == 1)
        #expect(exam.folderIDs == [Self.week1, Self.week2])
        #expect(exam.weekLabels == ["Week 1", "Week 2"])
    }

    @Test func updateRenamesAndSetsTheFoldersInHerOrder() async throws {
        let fixture = try Fixture.load("course-exam-update")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let exam = try await client.updateCourseExam(id: Self.examOne, name: "Midterm", folderIDs: [Self.week2, Self.week1])
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(exam.id == Self.examOne)
        #expect(exam.name == "Midterm")
        #expect(exam.folderIDs == [Self.week2, Self.week1], "the page keeps the order sent")
    }

    @Test func createFolderMakesAnEmptyOneOnNoExamPage() async throws {
        let fixture = try Fixture.load("folder-create")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let folder = try await client.createFolder(courseID: courseID(of: fixture), name: "First Pass")
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(folder.id == Self.firstPass)
        #expect(folder.name == "First Pass")
        #expect(folder.examPageID == nil)
        #expect(folder.sets.isEmpty)
        #expect(folder.sortOrder == 1, "the order counts within the Folders list, where it is the only folder on no exam page")
    }

    @Test func renameChangesOnlyTheName() async throws {
        let fixture = try Fixture.load("folder-rename")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let folder = try await client.renameFolder(id: Self.firstPass, name: "Mixed review")
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(folder.id == Self.firstPass)
        #expect(folder.name == "Mixed review")
        #expect(folder.examPageID == nil)
    }

    @Test func placeFolderPutsItOnAPageAndTakesItOff() async throws {
        let on = try Fixture.load("folder-put-on-page")
        let off = try Fixture.load("folder-take-off-page")
        let transport = try FixtureTransport([on, off])
        let (client, _) = TestClient.make(transport)
        let placed = try await client.placeFolder(id: Self.firstPass, onExamPage: Self.examTwo)
        try expectRequest(transport.requests.first, matches: on)
        #expect(placed.examPageID == Self.examTwo)
        let loose = try await client.placeFolder(id: Self.firstPass, onExamPage: nil)
        try expectRequest(transport.requests.last, matches: off)
        #expect(loose.examPageID == nil)
        #expect(off.request.body?["examPageId"] == .null, "taking it off is sent as null, not left out")
    }

    @Test func moveSetToAFolderOrANewOne() async throws {
        let toFolder = try Fixture.load("practice-set-move")
        let toNew = try Fixture.load("practice-set-move-new-folder")
        let transport = try FixtureTransport([toFolder, toNew])
        let (client, _) = TestClient.make(transport)
        let set = "5e700000-0000-4000-8000-000000000004"
        let first = try await client.moveSet(id: set, toFolder: Self.firstPass)
        try expectRequest(transport.requests.first, matches: toFolder)
        #expect(first.id == Self.firstPass)
        #expect(first.sets.map(\.id) == [set], "the folder it is in now, with its sets")
        let second = try await client.moveSet(id: set, toNewFolder: "Second Pass")
        try expectRequest(transport.requests.last, matches: toNew)
        #expect(second.id == Self.secondPass)
        #expect(second.name == "Second Pass")
        #expect(second.examPageID == nil)
    }

    @Test func folderOrderSavesOneList() async throws {
        let fixture = try Fixture.load("folder-order")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let folders = try await client.setFolderOrder(courseID: courseID(of: fixture), examPageID: Self.examOne, folderIDs: [Self.week1, Self.week2])
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(folders.map(\.id) == [Self.week1, Self.week2])
        #expect(folders.map(\.sortOrder) == [1, 2])
    }

    /// The course's folders come in the course's order: each page's folders, pages in order, then
    /// the folders on no exam page, each list in her order.
    @Test func courseListsItsPagesAndFoldersInOrder() throws {
        let course = try Fixture.load("course-with-exams").decodeBody(CourseDetail.self)
        #expect(course.exams.map(\.name) == ["Midterm", "Exam 2"])
        #expect(course.exams.map(\.folderIDs) == [[Self.week1, Self.week2], [Self.week3]])
        #expect(course.folders.map(\.name) == ["Week 1", "Week 2", "Week 3", "Mixed review", "Second Pass"])
        #expect(course.folders.map(\.examPageID) == [Self.examOne, Self.examOne, Self.examTwo, nil, nil])
        #expect(course.folders.map(\.sets.count) == [1, 1, 1, 0, 1], "an empty folder is listed too")
        #expect(course.folderCount == 5)
        #expect(course.weekCount == 4)
    }

    /// A past exam belongs to the page holding every folder it covered; one across two pages belongs to none.
    @Test func pastExamsNameTheirExamPage() throws {
        let setup = try Fixture.load("exam-setup-course-exams").decodeBody(ExamSetup.self)
        #expect(setup.exams.map(\.folderIDs) == [[Self.week1, Self.week2, Self.week3], [Self.week1, Self.week2]])
        #expect(setup.exams.map(\.courseExamID) == [nil, Self.examOne])
        #expect(setup.folders.map(\.name) == ["Week 1", "Week 2", "Week 3", "Second Pass"], "folders with questions, in the course's order")
        #expect(setup.folders.map(\.examPageID) == [Self.examOne, Self.examOne, Self.examTwo, nil])
    }

    /// Each exam page's plan, for its Start exam line: every question of its folders.
    @Test func setupPlansAnExamOverEachPage() throws {
        let setup = try Fixture.load("exam-setup-course-exams").decodeBody(ExamSetup.self)
        #expect(setup.courseExams.map(\.courseExamID) == [Self.examOne, Self.examTwo])
        #expect(setup.courseExams.map(\.preview.questionCount) == [5, 2])
        #expect(setup.courseExams.map(\.preview.timeLimitSeconds) == [450, 180])
        #expect(setup.courseExams.first?.preview.folders.map(\.id) == [Self.week1, Self.week2])
        #expect(setup.courseExams.first?.preview.folders.map(\.source) == [.practice, .practice])
    }

    @Test(arguments: [
        ("course-exam-create-folder-taken", 409, "Week 2 is in Exam 1."),
        ("course-exam-create-name-taken", 409, "This course already has a page named exam 1."),
        ("course-exam-create-unknown-folder", 400, "That folder is not in this course."),
        ("course-exam-create-blank", 400, "Page name is required."),
        ("course-exam-update-folder-taken", 409, "Week 1 is in Midterm."),
        ("course-exam-not-found", 404, "That page is not in the app."),
    ])
    func examPageRefusalsSayWhyInHerWords(name: String, status: Int, message: String) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let body = fixture.request.body
        let folders = body?["folderIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let id = String(fixture.request.path.split(separator: "/").last!)
        let error = await #expect(throws: QBankError.self) {
            switch fixture.request.method {
            case "POST":
                _ = try await client.createCourseExam(courseID: courseID(of: fixture), name: body?["name"]?.stringValue ?? "", folderIDs: folders)
            case "PUT":
                _ = try await client.updateCourseExam(id: id, name: body?["name"]?.stringValue ?? "", folderIDs: folders)
            default:
                _ = try await client.courseExamDeletion(id: String(fixture.request.path.split(separator: "/")[2]))
            }
        }
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(error == .server(ServerError(status: status, code: .requestRefused, message: message)))
        #expect(error?.needsSignIn == false)
    }

    @Test(arguments: [
        ("folder-create-taken", 409, "NURS 101 already has a folder named First Pass."),
        ("folder-create-blank", 400, "Folder name is required."),
        ("folder-rename-taken", 409, "Midterm already has a folder named Week 1."),
        ("folder-not-found", 404, "That folder is not in the app."),
        ("practice-set-move-new-folder-taken", 409, "NURS 101 already has a folder named Mixed review."),
        ("folder-order-stale", 409, "The folders changed since this list was shown. Reload and try again."),
    ])
    func folderRefusalsSayWhyInHerWords(name: String, status: Int, message: String) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let body = fixture.request.body
        let parts = fixture.request.path.split(separator: "/").map(String.init)
        let error = await #expect(throws: QBankError.self) {
            switch (fixture.request.method, parts.last) {
            case ("POST", "folders"):
                try await client.createFolder(courseID: parts[2], name: body?["name"]?.stringValue ?? "")
            case ("PATCH", _):
                try await client.renameFolder(id: parts[2], name: body?["name"]?.stringValue ?? "")
            case ("POST", "move"):
                try await client.moveSet(id: parts[2], toNewFolder: body?["newFolderName"]?.stringValue ?? "")
            default:
                let folders = body?["folderIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                try await client.setFolderOrder(courseID: parts[2], examPageID: body?["examPageId"]?.stringValue, folderIDs: folders)
            }
        }
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(error == .server(ServerError(status: status, code: .requestRefused, message: message)))
    }

    /// A server from before course exams sends neither field: the course has no exams, and no
    /// past exam belongs to one.
    @Test func olderServerReadsAsNoExams() throws {
        guard case .object(var course) = try Fixture.load("course").response.body else {
            Issue.record("The course fixture is not an object")
            return
        }
        course["exams"] = nil
        course["examTimeLimitSeconds"] = nil
        let detail = try JSONValue.object(course).decode(CourseDetail.self)
        #expect(detail.exams.isEmpty)
        #expect(detail.weeks.count == 2)
        #expect(detail.examTimeLimitSeconds == nil, "as in a copy saved before the app read it")

        guard case .object(var setup) = try Fixture.load("exam-setup-in-progress").response.body,
              case .object(var running)? = setup["inProgress"] else {
            Issue.record("The exam setup fixture has no running exam")
            return
        }
        running["courseExamId"] = nil
        setup["inProgress"] = .object(running)
        let decoded = try JSONValue.object(setup).decode(ExamSetup.self)
        #expect(decoded.inProgress != nil)
        #expect(decoded.inProgress?.courseExamID == nil)
    }

    /// A server, or a copy saved on the phone, from before folders: each week reads as a folder
    /// named and identified by its label, on the exam page listing that label.
    @Test func olderServerReadsWeeksAsFolders() throws {
        guard case .object(var course) = try Fixture.load("course-with-exams").response.body,
              case .array(let exams)? = course["exams"] else {
            Issue.record("The course fixture is not an object with exams")
            return
        }
        course["folders"] = nil
        course["folderCount"] = nil
        course["exams"] = .array(exams.map { exam in
            guard case .object(var page) = exam else { return exam }
            page["folderIds"] = nil
            return .object(page)
        })
        let detail = try JSONValue.object(course).decode(CourseDetail.self)
        #expect(detail.folders.map(\.id) == ["Week 1", "Week 2", "Week 3", "Second Pass"])
        #expect(detail.folders.map(\.examPageID) == [Self.examOne, Self.examOne, Self.examTwo, nil])
        #expect(detail.folderCount == 4)
        #expect(detail.exams.allSatisfy { $0.folderIDs.isEmpty })

        guard case .object(var setup) = try Fixture.load("exam-setup-course-exams").response.body else {
            Issue.record("The exam setup fixture is not an object")
            return
        }
        setup["folders"] = nil
        let pools = try JSONValue.object(setup).decode(ExamSetup.self)
        #expect(pools.folders.map(\.id) == pools.weeks.map(\.label))
    }
}

@Suite("Contract: import")
struct ImportContractTests {
    static let course = "c0000000-0000-4000-8000-000000000301"
    static let week1 = "f0000000-0000-4000-8000-000000000301"
    static let week2 = "f0000000-0000-4000-8000-000000000302"
    static let unsorted = "f0000000-0000-4000-8000-000000000303"
    static let examOne = "ce000000-0000-4000-8000-000000000301"

    @Test func checkReadsTheCountsAndFormats() async throws {
        let fixture = try Fixture.load("import-check")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let report = try await client.checkImport(source: try source(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(report.ok)
        #expect(report.title == "Invented Depression Care")
        #expect(report.kind == .practice)
        #expect(report.questionCount == 3)
        #expect(report.termCount == 1)
        #expect(report.formats.map(\.label) == ["Single answer", "Select all that apply"])
        #expect(report.formats.map(\.count) == [2, 1])
        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
    }

    @Test func checkListsTheErrorsThatBlockIt() async throws {
        let fixture = try Fixture.load("import-check-errors")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let report = try await client.checkImport(source: try source(of: fixture))
        #expect(!report.ok)
        #expect(report.errors == ["Question 1 (Q1): missing takeaway", "Question 1 (Q1): needs exactly one option with \"ok\": true (found 2)"])
        #expect(report.warnings.count == 4)
        #expect(report.questionCount == 0)
    }

    @Test func checkOfTextThatIsNotJSONHasNoTitle() async throws {
        let fixture = try Fixture.load("import-check-not-json")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let report = try await client.checkImport(source: try source(of: fixture))
        #expect(!report.ok)
        #expect(report.title == nil)
        #expect(report.errors.first?.hasPrefix("This is not valid JSON") == true)
    }

    @Test func checkSaysWhenTheFileIsAnExamSet() async throws {
        let fixture = try Fixture.load("import-check-exam")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let report = try await client.checkImport(source: try source(of: fixture))
        #expect(report.ok)
        #expect(report.kind == .exam)
    }

    @Test func importWithNoFolderGoesToUnsorted() async throws {
        let fixture = try Fixture.load("import")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let outcome = try await client.importSet(ImportRequest(source: try source(of: fixture), title: nil, course: .existing(id: Self.course), folder: .unsorted))
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .imported(let set) = outcome else {
            Issue.record("Expected an import, got \(outcome)")
            return
        }
        #expect(set.kind == .imported)
        #expect(set.setKind == .practice)
        #expect(set.courseID == Self.course)
        #expect(set.courseCode == "NURS 101")
        #expect(set.folderID == Self.unsorted)
        #expect(set.folderName == "Unsorted")
        #expect(set.examPageID == nil)
        #expect(set.questionCount == 3)
        #expect(set.termCount == 1)
    }

    @Test func importIntoAFolderWithHerSetName() async throws {
        let fixture = try Fixture.load("import-folder")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let request = ImportRequest(source: try source(of: fixture), title: "Anxiety, renamed", course: .existing(id: Self.course), folder: .id(Self.week2))
        let outcome = try await client.importSet(request)
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .imported(let set) = outcome else {
            Issue.record("Expected an import, got \(outcome)")
            return
        }
        #expect(set.title == "Anxiety, renamed")
        #expect(set.folderID == Self.week2)
        #expect(set.examPageID == Self.examOne, "Week 2 is on Exam 1")
    }

    @Test func importIntoANewFolderSheNames() async throws {
        let fixture = try Fixture.load("import-new-folder")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let outcome = try await client.importSet(ImportRequest(source: try source(of: fixture), title: nil, course: .existing(id: Self.course), folder: .named("First Pass")))
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .imported(let set) = outcome else {
            Issue.record("Expected an import, got \(outcome)")
            return
        }
        #expect(set.folderName == "First Pass")
    }

    @Test func importIntoANewCourse() async throws {
        let fixture = try Fixture.load("import-new-course")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let course = ImportRequest.Course.new(code: "NURS 102", title: "Invented Second Course", semesterNumber: 1)
        let outcome = try await client.importSet(ImportRequest(source: try source(of: fixture), title: nil, course: course, folder: .unsorted))
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .imported(let set) = outcome else {
            Issue.record("Expected an import, got \(outcome)")
            return
        }
        #expect(set.courseCode == "NURS 102")
        #expect(set.courseID != Self.course)
        #expect(set.folderName == "Unsorted")
    }

    @Test func aSetOfTheSameNameAsksFirst() async throws {
        let fixture = try Fixture.load("import-conflict")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let outcome = try await client.importSet(ImportRequest(source: try source(of: fixture), title: nil, course: .existing(id: Self.course), folder: .id(Self.week1)))
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .conflict(let conflict) = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        #expect(conflict.title == "Invented Depression Care")
        #expect(conflict.courseCode == "NURS 101")
        #expect(conflict.courseTitle == "Invented Nursing")
        #expect(conflict.folderID == Self.unsorted, "the existing set's folder, not the one the import named")
        #expect(conflict.folderName == "Unsorted")
        #expect(conflict.existingQuestionCount == 3)
        #expect(conflict.incomingQuestionCount == 4)
    }

    @Test(arguments: [
        ("import-replace", ImportRequest.Decision.replace, ImportedSet.Kind.replaced),
        ("import-separate", ImportRequest.Decision.separate, ImportedSet.Kind.imported),
    ])
    func herAnswerToTheConflict(name: String, decision: ImportRequest.Decision, kind: ImportedSet.Kind) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let asked = ImportRequest(source: try source(of: fixture), title: nil, course: .existing(id: Self.course), folder: .id(Self.week1))
        let outcome = try await client.importSet(asked.deciding(decision))
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .imported(let set) = outcome else {
            Issue.record("Expected an import, got \(outcome)")
            return
        }
        #expect(set.kind == kind)
        #expect(set.questionCount == 4)
        if decision == .replace {
            #expect(set.folderID == Self.unsorted, "a replaced set stays in its folder")
        } else {
            #expect(set.folderID == Self.week1)
        }
    }

    @Test func aRefusedFileIsAnError() async throws {
        let fixture = try Fixture.load("import-invalid")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.importSet(ImportRequest(source: try source(of: fixture), title: nil, course: .existing(id: Self.course), folder: .unsorted))
        }
        guard case .server(let server)? = error else {
            Issue.record("Expected a server error, got \(String(describing: error))")
            return
        }
        #expect(server.status == 400)
        #expect(server.code == .invalidImport)
        #expect(server.message == "Question 1 (Q1): missing takeaway")
    }

    @Test func anExamSetGoesToItsFolder() async throws {
        let fixture = try Fixture.load("import-exam")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let outcome = try await client.importSet(ImportRequest(source: try source(of: fixture), title: nil, course: .existing(id: Self.course), folder: .id(Self.week2)))
        try expectRequest(transport.requests.first, matches: fixture)
        guard case .imported(let set) = outcome else {
            Issue.record("Expected an import, got \(outcome)")
            return
        }
        #expect(set.setKind == .exam)
        #expect(set.folderName == "Week 2")
    }

    private func source(of fixture: Fixture) throws -> String {
        try #require(fixture.request.body?["source"]?.stringValue)
    }
}

@Suite("Contract: the recordings themselves")
struct FixtureTests {
    /// Every error the server sent decodes into a typed error with its code and message. The
    /// import's conflict is the route's own answer, not an error body.
    @Test func everyErrorBodyDecodes() throws {
        let failures = try Fixture.all().filter { $0.response.status >= 400 && $0.response.body["conflict"] == nil }
        #expect(failures.count >= 10)
        for fixture in failures {
            let response = HTTPURLResponse(url: TestClient.baseURL, statusCode: fixture.response.status, httpVersion: nil, headerFields: fixture.response.headers)!
            let error = QBankClient.failure(status: fixture.response.status, data: try fixture.responseData, response: response)
            guard case .server(let server) = error else {
                Issue.record("\(fixture.name) did not decode as a server error")
                continue
            }
            #expect(server.code.rawValue == fixture.response.body["error"]?.stringValue, "\(fixture.name)")
            #expect(!server.message.isEmpty, "\(fixture.name)")
        }
    }

    /// Every recorded call is a path and method the pinned OpenAPI file documents, with that status.
    @Test func everyRecordingIsInTheOpenAPIFile() throws {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        let spec = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let paths)? = spec["paths"] else {
            Issue.record("openapi.json has no paths")
            return
        }
        for fixture in try Fixture.all() {
            // A literal path such as /api/passkeys/options wins over a template beside it, /api/passkeys/{id}.
            let template = paths.keys.first { $0 == fixture.request.path }
                ?? paths.keys.first { matches(template: $0, path: fixture.request.path) }
            let operation = template.flatMap { paths[$0]?[fixture.request.method.lowercased()] }
            #expect(operation != nil, "\(fixture.name): \(fixture.request.method) \(fixture.request.path) is not in openapi.json")
            #expect(operation?["responses"]?[String(fixture.response.status)] != nil, "\(fixture.name): status \(fixture.response.status) is not documented")
        }
    }

    /// The recordings hold no real session token, only placeholders.
    @Test func recordingsHoldOnlyPlaceholderTokens() throws {
        for fixture in try Fixture.all() {
            if let authorization = fixture.request.authorization {
                #expect(authorization.hasPrefix("Bearer synthetic-"), "\(fixture.name)")
            }
            if let token = fixture.response.body["token"]?.stringValue {
                #expect(token.hasPrefix("synthetic-"), "\(fixture.name)")
            }
        }
    }

    private func matches(template: String, path: String) -> Bool {
        let left = template.split(separator: "/")
        let right = path.split(separator: "/")
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
    }
}

/// The course id in a recorded `/api/courses/{id}/...` path.
func courseID(of fixture: Fixture) -> String {
    let parts = fixture.request.path.split(separator: "/")
    return String(parts[2])
}

/// The folder ids a recorded request sent.
func folderIDs(of fixture: Fixture) -> [String] {
    fixture.request.body?["folderIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
}

extension SavedAttempt {
    /// What the server answers to a repeated id: the saved attempt with `replayed` set.
    static func replayOf(_ saved: SavedAttempt) -> SavedAttempt {
        SavedAttempt(
            clientAttemptID: saved.clientAttemptID, questionID: saved.questionID, courseID: saved.courseID,
            status: saved.status, points: saved.points, maxPoints: saved.maxPoints, guessed: saved.guessed,
            answeredAt: saved.answeredAt, inReview: saved.inReview, label: saved.label, pointsText: saved.pointsText,
            ruleText: saved.ruleText, replayed: true
        )
    }
}
