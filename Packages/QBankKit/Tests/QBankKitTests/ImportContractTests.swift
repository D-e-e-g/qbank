import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

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
