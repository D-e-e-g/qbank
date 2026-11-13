import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

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
