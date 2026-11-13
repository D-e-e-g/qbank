import Foundation
import QBankKit
import Testing
@testable import QBank

struct WordingTests {
    private let now = QBankJSON.parseDate("2026-10-12T15:00:00.000Z")!

    @Test func counts() {
        #expect(Wording.count(1, "question") == "1 question")
        #expect(Wording.count(86, "question") == "86 questions")
        #expect(Wording.size(questions: 1, folders: 3) == "1 question · 3 folders")
        #expect(Wording.size(questions: 86, folders: 1) == "86 questions · 1 folder")
    }

    @Test func todayOrAShortDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(Wording.when(now.addingTimeInterval(-3600), now: now, calendar: calendar) == "today")
        #expect(Wording.when(now.addingTimeInterval(-9 * 86_400), now: now, calendar: calendar) != "today")
    }

    /// The Exam tile says the server's time for an exam over every folder, whatever the old rules
    /// would have made of the question count.
    @Test(arguments: [
        (0, 0, "Not ready"), (4, 360, "6 min"), (5, 450, "7.5 min"), (40, 3600, "60 min"), (134, 3600, "60 min"),
        (134, 2700, "45 min"), (30, 1500, "25 min"), (30, nil, "Timed"),
    ] as [(Int, Int?, String)])
    func examTime(questions: Int, seconds: Int?, expected: String) {
        let course = CourseDetail(
            id: "c1", code: "NURS 101", title: "Invented Basics", archivedAt: nil, semester: nil, questionCount: questions,
            examQuestionCount: questions, weekCount: 0, termCount: 0, reviewCount: 0, answeredCount: 0, fullyRightCount: 0,
            points: 0, maxPoints: 0, weeks: [], examTimeLimitSeconds: seconds
        )
        #expect(Wording.examTime(course) == expected)
    }

    private static func set(
        _ status: String = "imported", answered: Int, right: Int = 0, last: String = "null", sitting: Int? = nil, run: String? = nil
    ) throws -> PracticeSetSummary {
        let sitting = sitting.map { #","sitting":{"answeredCount":\#($0)}"# } ?? ""
        let run = run.map { #","run":"\#($0)""# } ?? ""
        return try QBankJSON.decoder.decode(PracticeSetSummary.self, from: Data(#"""
        {"id":"s","title":"t","description":"","questionCount":17,"importedAt":"2026-10-12T09:00:00.000Z","activeSince":"2026-10-12T09:00:00.000Z","status":"\#(status)","canRestore":false,"answeredCount":\#(answered),"fullyRightCount":\#(right),"lastAnsweredAt":\#(last),"questionIds":[]\#(sitting)\#(run)}
        """#.utf8))
    }

    /// A row from a server before `run` reads by the counts and the sitting, as it always did.
    @Test func setStatusLines() throws {
        #expect(Wording.status(try Self.set("imported", answered: 0), now: now) == "Imported today · 17 questions")
        #expect(Wording.status(try Self.set("replaced", answered: 0), now: now) == "Replaced today · 17 questions")
        #expect(Wording.status(try Self.set("restored", answered: 0), now: now) == "Restored today · 17 questions")
        #expect(Wording.status(try Self.set("imported", answered: 9), now: now) == "9 of 17 answered")
        #expect(Wording.status(try Self.set("imported", answered: 9, sitting: 4), now: now) == "4 of 17 answered · Continue")
        #expect(Wording.status(try Self.set("imported", answered: 17, right: 13, last: #""2026-10-12T10:00:00.000Z""#), now: now) == "Done today · 13 of 17 fully right")
    }

    /// The server's `run` alone says which line a row shows, whatever the counts or the sitting say.
    @Test func setStatusFollowsTheRun() throws {
        let last = #""2026-10-12T10:00:00.000Z""#
        #expect(Wording.status(try Self.set(answered: 0, run: "new"), now: now) == "Imported today · 17 questions")
        #expect(Wording.status(try Self.set(answered: 9, sitting: 4, run: "midway"), now: now) == "4 of 17 answered · Continue")
        #expect(Wording.status(try Self.set(answered: 9, sitting: 4, run: "midway"), opens: false, now: now) == "9 of 17 answered")
        #expect(Wording.status(try Self.set(answered: 9, run: "restarted"), now: now) == "9 of 17 answered")
        #expect(Wording.status(try Self.set(answered: 17, right: 13, last: last, run: "done"), now: now) == "Done today · 13 of 17 fully right")
        // A Done set with a retake open never offers Continue, even if a sitting is listed.
        let retake = try Self.set(answered: 17, right: 13, last: last, sitting: 1, run: "done")
        #expect(Wording.continuing(retake) == nil)
        #expect(Wording.status(retake, now: now) == "Done today · 13 of 17 fully right")
    }

    @Test func newRunNotice() {
        #expect(Wording.newRunNotice == "You've answered this set before. Answering now starts a new practice run.")
    }

    @Test func answeredPercentRoundsAndCaps() throws {
        func course(questions: Int, answered: Int) throws -> CourseSummary {
            try QBankJSON.decoder.decode(CourseSummary.self, from: Data(#"""
            {"id":"c","code":"N","title":"T","sortOrder":1,"archivedAt":null,"questionCount":\#(questions),"weekCount":1,"reviewCount":0,"answeredCount":\#(answered),"fullyRightCount":0,"points":0,"maxPoints":0}
            """#.utf8))
        }
        #expect(Wording.answeredPercent(try course(questions: 86, answered: 35)) == 41)
        #expect(Wording.answeredPercent(try course(questions: 10, answered: 12)) == 100)
        #expect(Wording.answeredPercent(try course(questions: 0, answered: 0)) == 0)
    }

    @MainActor
    @Test func problemsInPlainWords() {
        #expect(Wording.problem(.server(ServerError(status: 401, code: .invalidCredentials, message: "That email or password is not right."))) == "That email or password is not right.")
        #expect(Wording.problem(.transport(.notConnectedToInternet)) == "No connection. Check Wi-Fi or cellular data and try again.")
        #expect(Wording.problem(.transport(.timedOut)) == "QBank took too long to answer. Try again.")
        #expect(Wording.problem(.transport(.cannotFindHost)) == "QBank could not be reached. Try again in a moment.")
        #expect(Wording.problem(.unexpectedResponse(status: 502, detail: "Bad Gateway")) == "QBank is having trouble right now. Try again in a moment.")
        #expect(Wording.problem(.unexpectedResponse(status: 200, detail: "")) == "Something went wrong. Try again.")
        #expect(Wording.problem(.cancelled) == nil)
    }

    @Test func formatsUseTheWebsLabels() {
        #expect(Wording.format(.single) == "Single answer")
        #expect(Wording.format(.priority) == "Priority / first action")
        #expect(Wording.format(.sata) == "Select all that apply")
        #expect(Wording.format(.highlight) == "Highlight")
        #expect(Wording.format(.order) == "Ordering")
        #expect(Wording.format(.match) == "Matching")
        #expect(Wording.format(.matrix) == "Matrix")
        #expect(Wording.format(.matrixmulti) == "Matrix, check all that fit")
        #expect(Wording.format(.cloze) == "Drop-down")
        #expect(Wording.format(nil) == "Question")
    }

    @Test func durationIsSecondsThenWholeMinutes() {
        #expect(Wording.duration(0) == "0 sec")
        #expect(Wording.duration(44.6) == "45 sec")
        #expect(Wording.duration(59.4) == "59 sec")
        #expect(Wording.duration(60) == "1 min")
        #expect(Wording.duration(89) == "1 min")
        #expect(Wording.duration(90) == "2 min")
        #expect(Wording.duration(24 * 60 + 10) == "24 min")
        #expect(Wording.duration(-5) == "0 sec")
    }

    @Test func savedTimesAreTheTimeTodayOrTheDate() {
        let earlier = now.addingTimeInterval(-60)
        let today = Wording.time(earlier, now: earlier.addingTimeInterval(60))
        #expect(today == earlier.formatted(date: .omitted, time: .shortened))
        let old = now.addingTimeInterval(-9 * 86_400)
        #expect(Wording.time(old, now: now) == old.formatted(.dateTime.month(.abbreviated).day()))
        #expect(Wording.saved(old, now: now) == "Saved \(Wording.time(old, now: now))")
    }

    @Test func waitingAnswersInWords() {
        #expect(Wording.waitingToSend(3) == "3 waiting to send")
        let first = now.addingTimeInterval(-240)
        #expect(Wording.answered(from: first, to: first, now: now) == "answered \(Wording.time(first, now: now))")
        #expect(Wording.answered(from: first, to: now, now: now) == "answered \(Wording.time(first, now: now)) to \(Wording.time(now, now: now))")
    }

    @Test func savedCoursesInWords() {
        func course(_ code: String, saved: Int, of total: Int, at date: Date) -> SavedCourse {
            SavedCourse(id: code, kind: .course, code: code, title: "T", questionCount: total, savedQuestionCount: saved, isComplete: saved == total, savedAt: date)
        }
        let old = now.addingTimeInterval(-9 * 86_400)
        let updated = "updated \(Wording.time(now, now: now))"
        #expect(Wording.savedCourse(course("A", saved: 86, of: 86, at: now), now: now) == "86 questions · \(updated)")
        #expect(Wording.savedCourse(course("A", saved: 70, of: 86, at: now), now: now) == "70 of 86 questions · \(updated)")
        #expect(Wording.savedCourses([course("A", saved: 1, of: 1, at: old), course("B", saved: 1, of: 1, at: now)], now: now) == "2 courses · \(updated)")
        #expect(Wording.savedCourses([], now: now) == "Nothing saved yet")
    }

    // MARK: Courses and study topics

    /// A course and a topic both have pages; only what each is called differs.
    @Test func aCourseAndATopicDifferOnlyInWhatTheyAreCalled() {
        #expect(Wording.words(.course) == KindWords(container: "course"))
        #expect(Wording.words(.topic) == KindWords(container: "topic"))
        #expect(Wording.words(CourseKind(rawValue: "shelf")) == Wording.words(.course), "a kind this version does not know reads as a course")
    }

    /// A page deleted elsewhere says page, in the course's or topic's words, as the web does.
    @Test func aPageDeletedElsewhereSaysPage() {
        #expect(KindWords.course.pageGone == "This page is not in the course anymore. If it was deleted, Recently deleted in the course can bring it back.")
        #expect(KindWords.topic.pageGone == "This page is not in the topic anymore. If it was deleted, Recently deleted in the topic can bring it back.")
    }

    /// A badge says what the page is for, in one word.
    @Test func eachBadgeHasItsWord() {
        #expect(PageBadge.allCases.map(Wording.badge) == ["Exam", "Concept", "Study"])
    }

    /// An exam page's warning title, Undo bar lines and Recently deleted line.
    @Test func aDeletedExamPageIsCalledByItsName() {
        let page = DeleteTarget.examPage(id: "p", name: "Exam 2")
        #expect(DeleteWording.question(page) == "Delete Exam 2?")
        #expect(DeleteWording.deleted(page) == "Exam 2 deleted.")
        #expect(DeleteWording.back(page) == "Exam 2 is back.")
        let deleted = { (names: [String]) in
            DeletedExamPage(id: "p", name: "Exam 2", folders: names.map { DeletedExamPage.Folder(id: $0, name: $0) }, pastExamCount: 0, deletedAt: .now, undoUntil: .now, undoRefusal: nil)
        }
        #expect(RecentlyDeletedWording.folders(deleted([])) == "No folders")
        #expect(RecentlyDeletedWording.folders(deleted(["Week 3", "Week 4"])) == "Week 3, Week 4")
        #expect(RecentlyDeletedWording.folders(deleted(["Week 3", "Week 4", "Week 5"])) == "Week 3, Week 4, Week 5")
        #expect(RecentlyDeletedWording.folders(deleted(["First Pass", "Second Pass", "Week 3", "Week 4", "Week 5"])) == "First Pass, Second Pass and 3 more")
    }

    @Test func aCourseIsCalledByItsCodeAndATopicByItsName() {
        let course = CourseRef(id: "c1", code: "NURS 420", title: "Health assessment")
        let topic = CourseRef(id: "t1", code: "", title: "Invented Systems Design", kind: .topic)
        #expect(Wording.name(course) == "NURS 420")
        #expect(Wording.line(course) == "NURS 420 · Health assessment")
        #expect(Wording.name(topic) == "Invented Systems Design")
        #expect(Wording.line(topic) == "Invented Systems Design")
    }

    @Test func aBodyWithoutAKindNamesATopicByItsName() {
        #expect(Wording.kind(code: "NURS 310") == .course)
        #expect(Wording.kind(code: "") == .topic)
        #expect(Wording.name(code: "NURS 310", title: "Mental Health") == "NURS 310")
        #expect(Wording.name(code: "", title: "Invented Systems Design") == "Invented Systems Design")
    }

    @Test func newMakesTheNextFreePageInACourseOrTopic() {
        #expect(Wording.nextPageName(after: []) == "Page 1")
        #expect(Wording.nextPageName(after: ["Page 1"]) == "Page 2")
        #expect(Wording.nextPageName(after: ["Exam 1", "Exam 2"]) == "Page 3", "her pages keep their names and count")
        #expect(Wording.nextPageName(after: ["Caching", " page 2 "]) == "Page 3")
    }

    @Test func aTopicsLineUnderItsTitleLeavesOutItsName() throws {
        let course = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(Bodies.courseDetail().utf8))
        #expect(Wording.summary(course) == "Invented Basics · 10 questions · 1 folder")
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Data(StudyBodies.topicDetail().utf8))
        #expect(Wording.summary(topic) == "4 questions · 2 folders")
    }

    // MARK: Connect an agent, worded as the web's agents.ts and AgentsScreen.tsx

    private func agentKey(created: Date, lastUsed: Date? = nil, revoked: Date? = nil) -> AgentKey {
        AgentKey(id: "k1", name: "My MacBook agent", scopes: [.import], createdAt: created, lastUsedAt: lastUsed, revokedAt: revoked)
    }

    private func pairing(scopes: [AgentScope] = [.import, .manage], texts: [AgentPairing.ScopeText]? = nil) -> AgentPairing {
        AgentPairing(
            name: "My MacBook agent", scopes: scopes,
            scopeTexts: texts ?? [
                .init(scope: .import, text: "Import question sets into your courses and topics."),
                .init(scope: .manage, text: "Add, change and delete your courses, topics, folders and sets. Anything it deletes goes to Recently deleted."),
            ],
            status: .pending, createdAt: now, expiresAt: now.addingTimeInterval(600)
        )
    }

    @Test func theAgentScreensFixedLinesAreTheWebs() {
        #expect(AgentWording.settingsDetail == "Approve its code, and see your keys")
        #expect(AgentWording.intro == "Your agent shows you a short code. Enter it here to see what the agent asks to do, then approve or deny it. You never see or copy a key: the agent picks its own up.")
        #expect(AgentWording.codeHint == "The code your agent shows you, such as BCDF\u{2011}GHJK. It lasts 10 minutes.", "a non-breaking hyphen")
        #expect(AgentWording.noCode == "Enter the code your agent shows you.")
        #expect(AgentWording.loadingKeys == "Loading your keys.")
        #expect(AgentWording.noKeys == "No agent keys yet. When you approve an agent, its key shows here.")
        #expect(AgentWording.keysFooter == "Each key works for this account only, and only for what it was approved to do. Revoking one stops it at once; what it imported or changed stays as it is.")
        #expect(AgentWording.revokedKey == "Revoked: it never works again")
        #expect(AgentWording.mostAccess == "Most access")
        #expect(AgentWording.approved("My MacBook agent") == "Approved My MacBook agent. It picks up its key within a few seconds, and then it shows under Your keys.")
        #expect(AgentWording.denied("My MacBook agent") == "Denied My MacBook agent. No key was made.")
        #expect(AgentWording.revokeTitle("My MacBook agent") == "Revoke My MacBook agent?")
        #expect(AgentWording.revoked("My MacBook agent") == "Revoked My MacBook agent. It stopped working just now.")
        #expect(AgentWording.importedBy == "Imported by your agent")
    }

    @Test func theCodeIsTrimmedAndInCapitalsWithItsDashOrWithout() {
        #expect(AgentWording.cleanCode("  bcdf-ghjk \n") == "BCDF-GHJK")
        #expect(AgentWording.cleanCode("bcdfghjk") == "BCDFGHJK")
        #expect(AgentWording.cleanCode("   ") == "")
    }

    @Test func importIsSaidPlainlyAndNeverReplacesOrDeletesASet() {
        #expect(AgentWording.scopeWords(.import, admin: false) == .init(
            title: "Import question sets",
            detail: "Into the courses and topics of your account, reading them to file each set. It never replaces, moves, renames, or deletes a set."
        ))
        #expect(AgentWording.scopeWords(.import, admin: true).detail == "It reaches nothing. An agent key reaches only its own account's content, and the admin account has none.")
    }

    @Test func readIsReadOnly() {
        #expect(AgentWording.scopeWords(.read, admin: false) == .init(
            title: "Read progress, read-only",
            detail: "Where you stand by topic, your Review lists, your exams, and your progress export. It changes nothing."
        ))
    }

    @Test func manageAddsChangesAndDeletesWithEveryDeleteInRecentlyDeleted() {
        #expect(AgentWording.scopeWords(.manage, admin: false) == .init(
            title: "Add, change, and delete your content",
            detail: "The sets, questions, folders, courses, and topics of your account, as you can in QBank. Anything it deletes goes to Recently deleted, where Undo brings it back for 30 days."
        ))
        #expect(AgentWording.scopeWords(.manage, admin: true) == .init(
            title: "Add, change, and delete content",
            detail: "It reaches nothing. An agent key reaches only its own account's content, and the admin account has none."
        ))
        #expect(AgentWording.isStrongest(.manage))
        #expect(!AgentWording.isStrongest(.import))
        #expect(!AgentWording.isStrongest(.read))
    }

    @Test func aScopeAddedLaterShowsByItsName() {
        #expect(AgentWording.scopeWords(AgentScope(rawValue: "export"), admin: false) == .init(title: "export", detail: "QBank has not described this one here yet."))
    }

    @Test func eachAskedScopeHasTheServersWordsInItsOrderUnderAShortTitle() {
        #expect(AgentWording.pairingScopes(pairing(), admin: false) == [
            .init(scope: .import, title: "Import question sets", detail: "Import question sets into your courses and topics.", isStrongest: false),
            .init(
                scope: .manage, title: "Add, change, and delete your content",
                detail: "Add, change and delete your courses, topics, folders and sets. Anything it deletes goes to Recently deleted.", isStrongest: true
            ),
        ])
        let fallback = AgentWording.pairingScopes(pairing(scopes: [.import, .read], texts: [.init(scope: .import, text: "Server words.")]), admin: false)
        #expect(fallback.map(\.detail) == ["Server words.", AgentWording.scopeWords(.read, admin: false).detail], "its own words only where the server sent none")
    }

    @Test func theCodeLineSaysWhenItStopsWorking() {
        let ends = now.addingTimeInterval(600).formatted(date: .omitted, time: .shortened)
        #expect(AgentWording.codeLine("JJHN-ZNKD", pairing()) == "Code JJHN-ZNKD · Works until \(ends)")
    }

    @Test func theNoteSaysAKeyNeverDeletesUnlessItManagesAndThenWithUndo() {
        #expect(AgentWording.approvalNote([.import, .read]) == "Approve only a code your own agent is showing you now. Its key never changes a password, deletes anything, or reaches your other keys.")
        #expect(AgentWording.approvalNote([.import, .manage]) == "Approve only a code your own agent is showing you now. Its key never answers questions for you, changes a password, or reaches your other keys, and what it deletes goes to Recently deleted.")
    }

    @Test func aKeysRowSaysWhatItCanDoInAFewWords() {
        let manage = "add, change, and delete your sets, questions, folders, courses, and topics. What it deletes goes to Recently deleted."
        #expect(AgentWording.scopesLine([.import]) == "Can import sets")
        #expect(AgentWording.scopesLine([.import, .read]) == "Can import sets and read progress")
        #expect(AgentWording.scopesLine([.import, .read, AgentScope(rawValue: "export")]) == "Can import sets, read progress and export")
        #expect(AgentWording.scopesLine([]) == "Can do nothing")
        #expect(AgentWording.scopesLine([.manage]) == "Can \(manage)")
        #expect(AgentWording.scopesLine([.import, .manage]) == "Can \(manage)")
        #expect(AgentWording.scopesLine([.import, .read, .manage]) == "Can read progress, and \(manage)")
    }

    @Test func revokingSaysWhatItLeaves() {
        #expect(AgentWording.revokeMessage([.import]) == "Its key stops working at once and for good. The sets it imported stay where they are. To connect this agent again, approve a new code from it.")
        #expect(AgentWording.revokeMessage([.import, .manage]) == "Its key stops working at once and for good. What it imported or changed stays as it is, and what it deleted stays in Recently deleted. To connect this agent again, approve a new code from it.")
    }

    @Test func aKeySaysWhenItWasMadeAndLastUsedOrRevoked() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let earlier = now.addingTimeInterval(-9 * 86_400)
        let day = Wording.when(earlier, now: now, calendar: calendar)
        #expect(AgentWording.keyDates(agentKey(created: earlier), now: now, calendar: calendar) == "Made \(day) · Never used")
        #expect(AgentWording.keyDates(agentKey(created: earlier, lastUsed: now), now: now, calendar: calendar) == "Made \(day) · Last used today")
        #expect(AgentWording.keyDates(agentKey(created: now), now: now, calendar: calendar) == "Made today · Never used")
        #expect(AgentWording.keyDates(agentKey(created: earlier, lastUsed: now, revoked: now), now: now, calendar: calendar) == "Made \(day) · Revoked today", "revoked, not last used")
    }

    /// Always "agent": never the name of the agent she happens to use.
    @Test func theAgentWordsNeverNameAProduct() {
        var lines = [
            AgentWording.settingsDetail, AgentWording.intro, AgentWording.codeHint, AgentWording.noCode, AgentWording.loadingKeys,
            AgentWording.noKeys, AgentWording.keysFooter, AgentWording.revokedKey, AgentWording.mostAccess,
            AgentWording.importedBy,
        ]
        for scopes in [[AgentScope.import], [.import, .read], [.import, .manage], [AgentScope(rawValue: "export")]] {
            lines += [AgentWording.approvalNote(scopes), AgentWording.scopesLine(scopes), AgentWording.revokeMessage(scopes)]
            for scope in scopes {
                for admin in [false, true] {
                    let words = AgentWording.scopeWords(scope, admin: admin)
                    lines += [words.title, words.detail]
                }
            }
        }
        for line in lines {
            #expect(!line.localizedCaseInsensitiveContains("firstmate"), "\(line)")
            #expect(!line.localizedCaseInsensitiveContains("student"), "\(line)")
        }
    }
}
