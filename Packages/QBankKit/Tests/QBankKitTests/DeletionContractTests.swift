import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// Deleting a course or study topic, an exam page, a set, a folder with its sets, and a past exam, Undo, and
/// Recently deleted, against recordings of the server's real routes: each call sends what the
/// recorded request sent, and each recorded response decodes into the models.
@Suite("Contract: deleting and Undo")
struct DeletionContractTests {
    static let course = "c0000000-0000-4000-8000-000000000701"
    static let week1 = "f0000000-0000-4000-8000-000000000701"
    static let week2 = "f0000000-0000-4000-8000-000000000702"
    static let exam1 = "ce000000-0000-4000-8000-000000000701"
    static let heartA = "5e700000-0000-4000-8000-000000000701"
    static let heartB = "5e700000-0000-4000-8000-000000000702"
    static let heartExam = "5e700000-0000-4000-8000-000000000703"
    static let lungs = "5e700000-0000-4000-8000-000000000704"
    static let kidneys = "5e700000-0000-4000-8000-000000000705"
    static let pastExam = "e0000000-0000-4000-8000-000000000701"
    static let runningExam = "e0000000-0000-4000-8000-000000000702"
    static let nurs220 = "c0000000-0000-4000-8000-000000000801"
    static let pharmacology = "c0000000-0000-4000-8000-000000000802"
    static let semester2 = "a0000000-0000-4000-8000-000000000802"
    static let nurs101 = "c0000000-0000-4000-8000-000000000901"
    static let pageExam1 = "ce000000-0000-4000-8000-000000000901"
    static let pageExam2 = "ce000000-0000-4000-8000-000000000902"
    static let newExam2 = "ce000000-0000-4000-8000-000000000903"
    static let pageWeek3 = "f0000000-0000-4000-8000-000000000902"
    static let pageWeek4 = "f0000000-0000-4000-8000-000000000903"
    static let pageWeek5 = "f0000000-0000-4000-8000-000000000904"

    // MARK: A set

    @Test func aSetsPreviewNamesWhatGoesAndHowHerStandingChanges() async throws {
        let fixture = try Fixture.load("practice-set-delete-preview")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.practiceSetDeletion(id: Self.heartB)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.setID == Self.heartB)
        #expect(preview.title == "Heart B")
        #expect(preview.kind == .practice)
        #expect(preview.folderID == Self.week1)
        #expect(preview.folderName == "Week 1")
        #expect(preview.examPageID == Self.exam1)
        #expect([preview.questionCount, preview.versionCount, preview.answeredCount, preview.reviewCount] == [3, 1, 1, 1] as [Int])
        #expect(preview.progress.answeredCount == CountChange(before: 7, after: 6))
        #expect(preview.progress.reviewCount == CountChange(before: 3, after: 2))
        #expect(preview.message == "Delete Heart B? Its 3 questions go with it. You have answered 1 of them: those answers stop counting toward your progress, and 1 question leaves your Review list. You can undo this for 30 days.")
        #expect(preview.refusal == nil)
        #expect(preview.confirm == "e1ce33d296348989")
        #expect(preview.undoDays == 30)
    }

    @Test func anExamSetsPreviewSaysItsFoldersExamsGoBackToPracticeQuestions() async throws {
        let fixture = try Fixture.load("practice-set-delete-preview-exam")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.practiceSetDeletion(id: Self.heartExam)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.kind == .exam)
        #expect(preview.message.hasPrefix("Delete Heart A exam from Week 1's exam bank?"))
    }

    @Test func aSetIsDeletedWithThePreviewsConfirmAndUndoBringsItBackInItsFolder() async throws {
        let transport = try FixtureTransport("practice-set-delete", "practice-set-undo-delete")
        let (client, _) = TestClient.make(transport)
        try await client.deletePracticeSet(id: Self.heartB, confirm: "e1ce33d296348989")
        let folder = try await client.undoDeletePracticeSet(id: Self.heartB)
        try expectRequest(transport.requests.first, matches: Fixture.load("practice-set-delete"))
        try expectRequest(transport.requests.last, matches: Fixture.load("practice-set-undo-delete"))
        #expect(folder.id == Self.week1)
        #expect(folder.sets.map(\.title) == ["Heart A", "Heart B"])
        #expect(folder.examBankCount == 3)
        #expect(folder.examSets == [ExamSetSummary(id: Self.heartExam, title: "Heart A exam", questionCount: 3)])
    }

    // MARK: A folder

    @Test func aFoldersPreviewNamesEverySetThatGoesWithIt() async throws {
        let fixture = try Fixture.load("folder-delete-preview")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.folderDeletion(id: Self.week1)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.folderID == Self.week1)
        #expect(preview.name == "Week 1")
        #expect(preview.examPageID == Self.exam1)
        #expect(preview.examPageName == "Exam 1")
        #expect(preview.sets.map(\.title) == ["Heart A", "Heart B", "Heart A exam"])
        #expect(preview.sets.map(\.kind) == [.practice, .practice, .exam])
        #expect([preview.setCount, preview.questionCount, preview.answeredCount, preview.reviewCount, preview.pastExamCount] == [3, 10, 4, 2, 0] as [Int])
        #expect(preview.message == "Delete Week 1? Its 3 sets go with it: Heart A, Heart B and Heart A exam, 10 questions in all. You have answered 4 of them: those answers stop counting toward your progress, and 2 questions leave your Review list. It comes off Exam 1. You can undo this for 30 days.")
        #expect(preview.refusal == nil)
        #expect(preview.confirm == "36a24767c0033cfc")
    }

    /// A set landed in the folder after she was warned: nothing is deleted, and a new preview names it.
    @Test func aFolderThatChangedSinceTheWarningIsRefusedAndPreviewedAgain() async throws {
        let transport = try FixtureTransport("folder-delete-changed", "folder-delete-preview-changed", "folder-delete")
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteFolder(id: Self.week1, confirm: "36a24767c0033cfc")
        }
        try MakeQuestionsContractTests.expect(error, is: Fixture.load("folder-delete-changed"), code: .deletionChanged)
        let again = try await client.folderDeletion(id: Self.week1)
        #expect(again.sets.map(\.title) == ["Heart A", "Heart B", "Heart C", "Heart A exam"])
        #expect(again.confirm != "36a24767c0033cfc")
        try await client.deleteFolder(id: Self.week1, confirm: again.confirm)
        let fixtures = try ["folder-delete-changed", "folder-delete-preview-changed", "folder-delete"].map(Fixture.load)
        for (request, fixture) in zip(transport.requests, fixtures) {
            try expectRequest(request, matches: fixture)
        }
    }

    /// The app always sends the preview's `confirm`; without one, a folder with sets is refused.
    @Test func aFolderWithSetsIsNotDeletedWithoutConfirm() throws {
        let fixture = try Fixture.load("folder-delete-unconfirmed")
        let response = try #require(HTTPURLResponse(url: TestClient.baseURL, statusCode: fixture.response.status, httpVersion: "HTTP/1.1", headerFields: nil))
        let error = QBankClient.failure(status: fixture.response.status, data: try fixture.responseData, response: response)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .confirmationRequired)
    }

    @Test func undoBringsTheFolderBackWithItsSets() async throws {
        let fixture = try Fixture.load("folder-undo-delete")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let folder = try await client.undoDeleteFolder(id: Self.week1)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(folder.examPageID == Self.exam1)
        #expect(folder.sets.map(\.title) == ["Heart A", "Heart B", "Heart C"])
        #expect(folder.examSets.map(\.title) == ["Heart A exam"])
    }

    // MARK: A past exam

    @Test func aPastExamsPreviewSaysWhichAnswersGoBack() async throws {
        let fixture = try Fixture.load("exam-delete-preview")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.examDeletion(id: Self.pastExam)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.examID == Self.pastExam)
        #expect(preview.courseID == Self.course)
        #expect(preview.finishedAt != nil)
        #expect([preview.questionCount, preview.answeredCount, preview.changedCount, preview.unansweredCount] == [3, 2, 1, 1] as [Int])
        #expect(preview.message == "Delete this exam? Your 2 answers on it go with it and stop counting toward your progress. 1 question goes back to your answer before it, and 1 question goes back to not answered. You can undo this for 30 days.")
        #expect(preview.refusal == nil)
    }

    @Test func aPastExamIsDeletedAndUndoListsItAgain() async throws {
        let transport = try FixtureTransport("exam-delete", "exam-undo-delete")
        let (client, _) = TestClient.make(transport)
        try await client.deleteExam(id: Self.pastExam, confirm: "3b71b71bc2530c3b")
        let exam = try await client.undoDeleteExam(id: Self.pastExam)
        try expectRequest(transport.requests.first, matches: Fixture.load("exam-delete"))
        try expectRequest(transport.requests.last, matches: Fixture.load("exam-undo-delete"))
        #expect(exam.id == Self.pastExam)
        #expect(exam.weeks == ["Week 2"])
        #expect(exam.endReason == .finished)
    }

    @Test func anExamStillGoingIsRefusedInHerWords() async throws {
        let preview = try Fixture.load("exam-delete-preview-in-progress")
        let refused = try Fixture.load("exam-delete-in-progress")
        let transport = try FixtureTransport([preview, refused])
        let (client, _) = TestClient.make(transport)
        let shown = try await client.examDeletion(id: Self.runningExam)
        #expect(shown.finishedAt == nil)
        #expect(shown.refusal == "This exam is still going. Finish or leave it, then delete it.")
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteExam(id: Self.runningExam, confirm: shown.confirm)
        }
        try expectRequest(transport.requests.first, matches: preview)
        try expectRequest(transport.requests.last, matches: refused)
        try MakeQuestionsContractTests.expect(error, is: refused, code: .examInProgress)
    }

    // MARK: Refusals

    @Test func aSetARunningExamAsksIsRefusedWithThePreviewsSentence() async throws {
        let preview = try Fixture.load("practice-set-delete-preview-in-use")
        let refused = try Fixture.load("practice-set-delete-in-use")
        let transport = try FixtureTransport([preview, refused])
        let (client, _) = TestClient.make(transport)
        let shown = try await client.practiceSetDeletion(id: Self.heartExam)
        #expect(shown.refusal == "An exam in progress asks questions from Heart A exam. Finish or leave that exam first.")
        let error = await #expect(throws: QBankError.self) {
            try await client.deletePracticeSet(id: Self.heartExam, confirm: shown.confirm)
        }
        try expectRequest(transport.requests.last, matches: refused)
        try MakeQuestionsContractTests.expect(error, is: refused, code: .inUse)
    }

    @Test(arguments: [
        ("practice-set-undo-expired", DeletionContractTests.kidneys, ServerError.Code.undoExpired),
        ("practice-set-undo-with-folder", DeletionContractTests.heartA, .requestRefused),
    ])
    func undoRefusalsSayWhyInHerWords(name: String, set: String, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.undoDeletePracticeSet(id: set) }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: code)
    }

    // MARK: An exam page

    @Test func anExamPagesPreviewSaysItsFoldersStayAndItsStandingIsTheSame() async throws {
        let fixture = try Fixture.load("course-exam-delete-preview")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.courseExamDeletion(id: Self.pageExam2)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.examPageID == Self.pageExam2)
        #expect(preview.courseID == Self.nurs101)
        #expect(preview.name == "Exam 2")
        #expect(preview.folders.map(\.id) == [Self.pageWeek3, Self.pageWeek4])
        #expect(preview.folders.map(\.name) == ["Week 3", "Week 4"])
        #expect(preview.folders.map(\.setCount) == [1, 2])
        #expect([preview.folderCount, preview.setCount, preview.questionCount, preview.examQuestionCount] == [2, 3, 5, 2] as [Int])
        #expect([preview.answeredCount, preview.pastExamCount] == [1, 1] as [Int])
        #expect(preview.progress.answeredCount == CountChange(before: 1, after: 1))
        #expect(preview.message == "Delete Exam 2? Its 2 folders stay, with their sets and your progress, under Folders: Week 3 and Week 4. Your 1 past exam over it stays. You can undo this for 30 days.")
        #expect(preview.refusal == nil)
        #expect(preview.confirm == "0a8ebda3b1da4351")
        #expect(preview.undoDays == 30)
    }

    /// A folder went on the page after she was warned: nothing is deleted, and a new preview names it.
    @Test func anExamPageThatChangedSinceTheWarningIsRefusedAndPreviewedAgain() async throws {
        let names = ["course-exam-delete-changed", "course-exam-delete-preview-changed", "course-exam-delete"]
        let transport = try FixtureTransport(names[0], names[1], names[2])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteCourseExam(id: Self.pageExam2, confirm: "0a8ebda3b1da4351")
        }
        try MakeQuestionsContractTests.expect(error, is: Fixture.load("course-exam-delete-changed"), code: .deletionChanged)
        let again = try await client.courseExamDeletion(id: Self.pageExam2)
        #expect(again.folders.map(\.name) == ["Week 3", "Week 4", "Week 5"])
        #expect(again.confirm != "0a8ebda3b1da4351")
        try await client.deleteCourseExam(id: Self.pageExam2, confirm: again.confirm)
        for (request, fixture) in try zip(transport.requests, names.map(Fixture.load)) {
            try expectRequest(request, matches: fixture)
        }
    }

    /// The app always sends the preview's `confirm`; without one, a page with folders is refused.
    @Test func anExamPageWithFoldersIsNotDeletedWithoutConfirm() throws {
        let fixture = try Fixture.load("course-exam-delete-unconfirmed")
        let response = try #require(HTTPURLResponse(url: TestClient.baseURL, statusCode: fixture.response.status, httpVersion: "HTTP/1.1", headerFields: nil))
        let error = QBankClient.failure(status: fixture.response.status, data: try fixture.responseData, response: response)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .confirmationRequired)
    }

    /// One of its folders has the name of a folder in the Folders list, where it would show: the
    /// preview says so, and the delete is refused with the same sentence.
    @Test func anExamPageWhoseFolderNameIsInTheFoldersListIsRefused() async throws {
        let preview = try Fixture.load("course-exam-delete-preview-name-taken")
        let refused = try Fixture.load("course-exam-delete-name-taken")
        let transport = try FixtureTransport([preview, refused])
        let (client, _) = TestClient.make(transport)
        let shown = try await client.courseExamDeletion(id: Self.newExam2)
        #expect(shown.message == "Delete Exam 2? Its folder First Pass stays, with its sets and your progress, under Folders. You can undo this for 30 days.")
        #expect(shown.refusal == "NURS 101 already has a folder named First Pass in its Folders list. Rename one of them before deleting Exam 2.")
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteCourseExam(id: Self.newExam2, confirm: shown.confirm)
        }
        try expectRequest(transport.requests.first, matches: preview)
        try expectRequest(transport.requests.last, matches: refused)
        try MakeQuestionsContractTests.expect(error, is: refused, code: .requestRefused)
    }

    /// Meanwhile its folders show on no page, at the end of the Folders list, with their sets.
    @Test func aDeletedExamPagesFoldersStayInTheCourseOnNoPage() throws {
        let course = try Fixture.load("course-after-exam-page-delete").decodeBody(CourseDetail.self)
        #expect(course.exams.map(\.id) == [Self.pageExam1])
        #expect(course.folders.map(\.name) == ["Week 1", "First Pass", "Week 3", "Week 4", "Week 5"])
        #expect(course.folders.map(\.examPageID) == [Self.pageExam1, nil, nil, nil, nil])
        let week4 = try #require(course.folders.first { $0.id == Self.pageWeek4 })
        #expect(week4.sets.map(\.title) == ["Kidneys A"])
        #expect(week4.examSets.map(\.title) == ["Kidneys A exam"])
        #expect(course.answeredCount == 1)
    }

    @Test func recentlyDeletedListsAnExamPageWithTheFoldersUndoPutsBack() async throws {
        let fixture = try Fixture.load("course-deleted-exam-page")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let deleted = try await client.recentlyDeleted(courseID: Self.nurs101)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(!deleted.isEmpty)
        #expect(deleted.folders.isEmpty && deleted.sets.isEmpty && deleted.exams.isEmpty)
        let page = try #require(deleted.examPages.first)
        #expect(page.id == Self.pageExam2)
        #expect(page.name == "Exam 2")
        #expect(page.folders.map(\.id) == [Self.pageWeek3, Self.pageWeek4, Self.pageWeek5])
        #expect(page.folders.map(\.name) == ["Week 3", "Week 4", "Week 5"])
        #expect(page.pastExamCount == 1)
        #expect(page.undoRefusal == nil)
        #expect(abs(page.undoUntil.timeIntervalSince(page.deletedAt) - 30 * 86_400) < 0.001)
        let taken = try Fixture.load("course-deleted-exam-page-name-taken").decodeBody(RecentlyDeleted.self)
        #expect(taken.examPages.first?.undoRefusal == "This course already has an exam named Exam 2. Rename one of them, then bring this one back.")
    }

    /// An empty `examPages` list, including a recording from before pages could be deleted, lists none.
    @Test func recentlyDeletedFromBeforeExamPagesListsNone() throws {
        let deleted = try Fixture.load("course-deleted").decodeBody(RecentlyDeleted.self)
        #expect(deleted.examPages.isEmpty)
        #expect(!deleted.folders.isEmpty)
    }

    @Test func undoBringsTheExamPageBackWithItsFolders() async throws {
        let fixture = try Fixture.load("course-exam-undo-delete")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let page = try await client.undoDeleteCourseExam(id: Self.pageExam2)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(page.id == Self.pageExam2)
        #expect(page.name == "Exam 2")
        #expect(page.sortOrder == 2)
        #expect(page.folderIDs == [Self.pageWeek3, Self.pageWeek4, Self.pageWeek5])
    }

    @Test(arguments: [
        ("course-exam-undo-delete-name-taken", ServerError.Code.requestRefused, pageExam2),
        ("course-exam-undo-expired", ServerError.Code.undoExpired, pageExam1),
    ])
    func undoOfAnExamPageIsRefusedInHerWords(name: String, code: ServerError.Code, id: String) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { _ = try await client.undoDeleteCourseExam(id: id) }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: code)
    }

    @Test func aDeletedExamPageIsNotFound() async throws {
        let fixture = try Fixture.load("course-exam-delete-gone")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { _ = try await client.courseExamDeletion(id: Self.pageExam2) }
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(error == .server(ServerError(status: 404, code: .requestRefused, message: "That exam page was deleted.")))
    }

    // MARK: Recently deleted

    @Test func recentlyDeletedListsFoldersWithTheirSetsSetsAndExams() async throws {
        let fixture = try Fixture.load("course-deleted")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let deleted = try await client.recentlyDeleted(courseID: Self.course)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(deleted.undoDays == 30)
        #expect(!deleted.isEmpty)
        let folder = try #require(deleted.folders.first)
        #expect(folder.id == Self.week1)
        #expect(folder.examPageID == Self.exam1)
        #expect(folder.sets.map(\.title) == ["Heart A", "Heart B", "Heart C", "Heart A exam"])
        #expect(folder.undoRefusal == nil)
        #expect(abs(folder.undoUntil.timeIntervalSince(folder.deletedAt) - 30 * 86_400) < 0.001)
        // A set that went with its folder is under it; one deleted on its own is listed by itself.
        // Kidneys was deleted 31 days ago, so it is not listed.
        #expect(deleted.sets.map(\.id) == [Self.lungs])
        #expect(deleted.sets.first?.folderID == Self.week2)
        #expect(deleted.sets.first?.folderName == "Week 2")
        let exam = try #require(deleted.exams.first)
        #expect(exam.id == Self.pastExam)
        #expect(exam.exam.weeks == ["Week 2"])
        #expect(exam.exam.fullyRight == 2)
        #expect(exam.undoUntil > exam.deletedAt)
    }

    // MARK: A course or study topic

    @Test func aCoursesPreviewAsksOnceNamingItsQuestions() async throws {
        let fixture = try Fixture.load("course-delete-preview")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.courseDeletion(id: Self.nurs220)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.courseID == Self.nurs220)
        #expect(preview.kind == .course)
        #expect(preview.code == "NURS 220")
        #expect(preview.title == "Fundamentals")
        #expect(preview.semester?.id == Self.semester2)
        #expect(preview.semester?.name == "Semester 2")
        #expect([preview.folderCount, preview.examPageCount, preview.setCount, preview.questionCount, preview.examQuestionCount] == [1, 0, 2, 5, 0] as [Int])
        #expect([preview.answeredCount, preview.reviewCount, preview.pastExamCount] == [1, 1, 1] as [Int])
        #expect(preview.message == "Delete NURS 220 and its 5 questions? You can bring it back for 30 days.")
        #expect(preview.refusal == nil)
        #expect(preview.confirm == "bed4d3e1a5eaf8b4")
        #expect(preview.undoDays == 30)
    }

    @Test func aTopicsPreviewNamesItByItsName() async throws {
        let fixture = try Fixture.load("topic-delete-preview")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let preview = try await client.courseDeletion(id: Self.pharmacology)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(preview.kind == .topic)
        #expect(preview.code == "")
        #expect(preview.semester == nil)
        #expect(preview.message == "Delete Pharmacology and its 3 questions? You can bring it back for 30 days.")
    }

    @Test func aCourseIsDeletedWithThePreviewsConfirm() async throws {
        let fixture = try Fixture.load("course-delete")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        try await client.deleteCourse(id: Self.nurs220, confirm: "bed4d3e1a5eaf8b4")
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func aCourseWithAnExamGoingIsRefusedWithThePreviewsSentence() async throws {
        let preview = try Fixture.load("course-delete-preview-in-use")
        let refused = try Fixture.load("course-delete-in-use")
        let transport = try FixtureTransport([preview, refused])
        let (client, _) = TestClient.make(transport)
        let shown = try await client.courseDeletion(id: Self.nurs220)
        #expect(shown.refusal == "An exam in NURS 220 is still going. Finish or leave that exam first.")
        let error = await #expect(throws: QBankError.self) {
            try await client.deleteCourse(id: Self.nurs220, confirm: shown.confirm)
        }
        try expectRequest(transport.requests.first, matches: preview)
        try expectRequest(transport.requests.last, matches: refused)
        try MakeQuestionsContractTests.expect(error, is: refused, code: .inUse)
    }

    @Test func homesRecentlyDeletedListsCoursesAndTopicsNewestFirst() async throws {
        let fixture = try Fixture.load("deleted-courses")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let deleted = try await client.recentlyDeletedCourses()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(deleted.undoDays == 30)
        #expect(deleted.courses.map(\.id) == [Self.pharmacology, Self.nurs220])
        let topic = try #require(deleted.courses.first)
        #expect(topic.kind == .topic)
        #expect(topic.semester == nil)
        #expect(topic.questionCount == 3)
        #expect(topic.undoRefusal == nil)
        #expect(abs(topic.undoUntil.timeIntervalSince(topic.deletedAt) - 30 * 86_400) < 0.001)
        let course = try #require(deleted.courses.last)
        #expect(course.code == "NURS 220")
        #expect(course.semester?.name == "Semester 2")
        #expect(course.undoRefusal == "Semester 2 already has a course with the code NURS 220. Rename one of them, then bring this one back.")
    }

    @Test func undoBringsATopicBackAsItsCard() async throws {
        let fixture = try Fixture.load("course-undo-delete")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let card = try await client.undoDeleteCourse(id: Self.pharmacology)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(card.id == Self.pharmacology)
        #expect(card.kind == .topic)
        #expect(card.title == "Pharmacology")
        #expect(card.questionCount == 3)
    }

    @Test func undoOfACourseWhoseCodeIsTakenSaysSoInHerWords() async throws {
        let fixture = try Fixture.load("course-undo-delete-code-taken")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) { try await client.undoDeleteCourse(id: Self.nurs220) }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .requestRefused)
    }
}
