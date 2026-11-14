import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

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
