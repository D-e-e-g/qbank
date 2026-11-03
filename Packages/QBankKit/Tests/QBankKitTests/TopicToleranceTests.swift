import Foundation
import Testing
@testable import QBankKit

/// A server with study topics: a topic is a course row of kind `topic` with no semester and an
/// empty code. The bodies are the recorded contract fixtures; they must decode, and her courses
/// must read exactly as before.
@Suite("Topics on the server, before the app shows them")
struct TopicToleranceTests {
    static let topicID = "70000000-0000-4000-8000-000000000001"

    /// The recorded response body. `semesters` and `place` keep the names the tests were written
    /// with; their files are the topic recordings, not the course-only ones.
    static func body(_ name: String) throws -> Data {
        let recorded = [
            "semesters": "semesters-with-topics",
            "place": "place-topic",
        ]
        return try Fixture.load(recorded[name] ?? name).responseData
    }

    /// The body with every `"kind": "topic"` made a kind this version does not know.
    static func withUnknownKind(_ name: String) throws -> Data {
        var text = String(decoding: try body(name), as: UTF8.self)
        for spaced in [#""kind": "topic""#, #""kind" : "topic""#, #""kind":"topic""#] {
            text = text.replacingOccurrences(of: spaced, with: spaced.replacingOccurrences(of: "topic", with: "shelf"))
        }
        return Data(text.utf8)
    }

    static func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw CocoaError(.coderReadCorrupt) }
        return object
    }

    /// The JSON object with these keys left out, as a server from before topics sends it.
    static func removing(_ keys: [String], from data: Data) throws -> Data {
        var object = try object(JSONDecoder().decode(JSONValue.self, from: data))
        for key in keys { object[key] = nil }
        return try JSONEncoder().encode(JSONValue.object(object))
    }

    @Test func homeListsHerCoursesAsBeforeWhenTheServerAlsoSendsTopics() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("semesters")])
        let (client, _) = TestClient.make(transport)
        let semesters = try await client.catalog().semesters
        #expect(transport.requests.first?.url?.path == "/api/semesters")
        let before = try QBankJSON.decoder.decode(Catalog.self, from: Self.removing(["topics"], from: Self.body("semesters")))
        #expect(semesters == before.semesters, "the topics key changes nothing Home shows")
        #expect(semesters.flatMap(\.courses).map(\.code) == ["NURS 101"])
        #expect(semesters.flatMap(\.courses).map(\.kind) == [.course])
        #expect(!semesters.flatMap(\.courses).contains { $0.id == Self.topicID }, "a topic is not one of a semester's courses")
    }

    @Test func aStudyPlaceNamingATopicOpensIt() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("place"), try Self.body("topic")])
        let (client, _) = TestClient.make(transport)
        let place = try #require(try await client.studyPlace())
        #expect(place == Self.topicID)
        let topic = try await client.course(id: place)
        #expect(transport.requests.map { $0.url?.path } == ["/api/me/place", "/api/courses/\(Self.topicID)"])
        #expect(topic.id == Self.topicID)
        #expect(topic.kind == .topic)
        #expect(topic.semester == nil)
        #expect(topic.code == "")
        #expect(topic.title == "Invented Pharmacology Review")
        #expect(topic.folders.map(\.name) == ["Cardiac drugs", "Unsorted"])
        #expect(topic.folders.map(\.examPageID) == ["ce000000-0000-4000-8000-000000000701", nil])
        #expect(topic.exams.map(\.name) == ["Page 1"])
        #expect(topic.exams.first?.folderIDs == ["f0000000-0000-4000-8000-000000000701"])
        #expect(topic.folderCount == 2)
        #expect(topic.questionCount == 3)
    }

    @Test func aCourseOfKindCourseKeepsItsSemester() throws {
        let recorded = try Fixture.load("course-with-exams")
        var object = try Self.object(recorded.response.body)
        object["kind"] = .string("course")
        let course = try QBankJSON.decoder.decode(CourseDetail.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(course == (try recorded.decodeBody(CourseDetail.self)))
        #expect(course.kind == .course)
        #expect(course.semester?.number == 1)
    }

    @Test func everythingFromBeforeTopicsIsACourse() throws {
        let course = try Fixture.load("course").decodeBody(CourseDetail.self)
        #expect(course.kind == .course)
        #expect(course.semester?.name == "Semester 1")
        let cards = try Fixture.load("semesters").decodeBody(Catalog.self).semesters.flatMap(\.courses)
        #expect(!cards.isEmpty)
        #expect(cards.allSatisfy { $0.kind == .course })
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Self.removing(["kind"], from: Self.body("topic")))
        #expect(topic.kind == .course, "a missing kind reads as a course")
        #expect(topic.semester == nil)
    }

    @Test func aKindThisVersionDoesNotKnowStillDecodes() throws {
        let detail = try QBankJSON.decoder.decode(CourseDetail.self, from: Self.withUnknownKind("topic"))
        #expect(detail.kind == CourseKind(rawValue: "shelf"))
        #expect(detail.kind != .course && detail.kind != .topic)
        #expect(detail.semester == nil)
        #expect(detail.folders.count == 2)

        let catalog = try QBankJSON.decoder.decode(Catalog.self, from: Self.withUnknownKind("semesters"))
        #expect(catalog.semesters.flatMap(\.courses).map(\.code) == ["NURS 101"])

        let card = try QBankJSON.decoder.decode(
            CourseSummary.self,
            from: Data(#"{"id": "x", "kind": "shelf", "code": "", "title": "Invented", "sortOrder": 1, "archivedAt": null, "questionCount": 0, "weekCount": 0, "reviewCount": 0, "answeredCount": 0, "fullyRightCount": 0, "points": 0, "maxPoints": 0}"#.utf8)
        )
        #expect(card.kind.rawValue == "shelf")
    }

    @Test func aSavedTopicReadsBackTheSame() async throws {
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Self.body("topic"))
        let directory = ContentCacheTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        for cache in [FileContentCache(directory: directory), InMemoryContentCache()] as [any ContentCache] {
            try await cache.store(topic, for: .course(topic.id), savedAt: savedAt)
            #expect(try await cache.value(for: .course(topic.id)) == Cached(value: topic, savedAt: savedAt))
        }
        let saved = try JSONDecoder().decode(JSONValue.self, from: QBankJSON.encoder.encode(topic))
        #expect(saved["kind"]?.stringValue == "topic")
        #expect(saved["semester"] == nil || saved["semester"]?.isNull == true)
    }

    @Test func waitingAnswersKeepATopicATopic() throws {
        let topic = try QBankJSON.decoder.decode(CourseDetail.self, from: Self.body("topic"))
        let progress = WaitingProgress(answers: [
            "9e000000-0000-4000-8000-000000070003": .init(status: .correct, answeredAt: Date(timeIntervalSince1970: 1_790_000_000)),
        ])
        let counted = progress.counting(topic)
        #expect(counted.kind == .topic)
        #expect(counted.semester == nil)
        #expect(counted.answeredCount == 2)

        let card = try #require(
            try QBankJSON.decoder.decode(JSONValue.self, from: Self.body("semesters"))["topics"]?.arrayValue?.first
        )
        let summary = try QBankJSON.decoder.decode(CourseSummary.self, from: JSONEncoder().encode(card))
        let countedCard = progress.counting(summary, saved: topic)
        #expect(countedCard.kind == .topic)
        #expect(countedCard.answeredCount == 2)
    }
}
