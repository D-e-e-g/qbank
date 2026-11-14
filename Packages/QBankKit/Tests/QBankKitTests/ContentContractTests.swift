import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

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
        #expect(set.questions.compactMap(\.type) == QuestionType.allCases.filter { $0 != .matrixmulti })
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
        let copy = try JSONDecoder().decode(JSONValue.self, from: QBankJSON.encoder.encode(set))
        // A kit that does not read the set's run yet leaves it out of the copy; one that does keeps it.
        if copy["run"] == nil { original.removeValue(forKey: "run") }
        #expect(copy == .object(original))
    }
}
