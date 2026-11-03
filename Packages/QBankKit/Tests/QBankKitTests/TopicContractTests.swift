import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// The calls the study topic screens make, against the pinned server contract
/// (`Fixtures/openapi.json`): what each sends, that its route and fields are documented there, and
/// that the recorded answers decode.
@Suite("Contract: study topics")
struct TopicContractTests {
    static func body(_ name: String) throws -> Data {
        try TopicToleranceTests.body(name)
    }

    static func sent(_ request: URLRequest?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: #require(request?.httpBody))
    }

    /// The pinned OpenAPI document.
    static func spec() throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: "openapi", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// The request body's properties of an operation, following one `$ref`.
    static func requestFields(_ path: String, _ method: String) throws -> Set<String> {
        let spec = try spec()
        var schema = try #require(spec["paths"]?[path]?[method]?["requestBody"]?["content"]?["application/json"]?["schema"], "\(method) \(path)")
        if let ref = schema["$ref"]?.stringValue {
            schema = try #require(spec["components"]?["schemas"]?[String(ref.split(separator: "/").last ?? "")])
        }
        guard case .object(let properties)? = schema["properties"] else { return [] }
        return Set(properties.keys)
    }

    @Test func homeReadsHerSemestersTopicsAndWhatSheArchived() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("semesters")])
        let (client, _) = TestClient.make(transport)
        let catalog = try await client.catalog()
        #expect(transport.requests.first?.url?.path == "/api/semesters")
        #expect(catalog.semesters.map(\.name) == ["Semester 1", "Semester 2"])
        #expect(catalog.semesters.map { $0.archivedAt != nil } == [false, true])
        #expect(catalog.topics.map(\.title) == ["Invented Pharmacology Review", "Invented Spanish Verbs"])
        #expect(catalog.topics.map(\.kind) == [.topic, .topic])
        #expect(catalog.topics.map { $0.archivedAt != nil } == [false, true])
        #expect(catalog.course(id: TopicToleranceTests.topicID)?.title == "Invented Pharmacology Review")
        #expect(catalog.everyCourse.map(\.code) == ["NURS 101", "", ""])
    }

    @Test func aCopySavedBeforeTopicsReadsAsSemestersWithNoTopics() throws {
        let semesters = try Fixture.load("semesters").decodeBody(Catalog.self).semesters
        let saved = try QBankJSON.encoder.encode(semesters)
        let catalog = try QBankJSON.decoder.decode(Catalog.self, from: saved)
        #expect(catalog == Catalog(semesters: semesters))
        #expect(catalog.topics.isEmpty)
        #expect(catalog.semesters.allSatisfy { $0.archivedAt == nil })
    }

    @Test func aCatalogSavedNowReadsBackTheSame() async throws {
        let catalog = try QBankJSON.decoder.decode(Catalog.self, from: Self.body("semesters"))
        let cache = InMemoryContentCache()
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        try await cache.store(catalog, for: .catalog, savedAt: savedAt)
        #expect(try await cache.value(for: .catalog) == Cached(value: catalog, savedAt: savedAt))
        #expect(CacheKey<Catalog>.catalog.name == "semesters", "the name a copy from before topics was saved under")
    }

    @Test func newTopicSendsItsNameOnly() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("topic-create")])
        let (client, _) = TestClient.make(transport)
        let topic = try await client.createTopic(title: "Invented Systems Design")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/topics")
        #expect(try Self.sent(request) == .object(["title": .string("Invented Systems Design")]))
        #expect(topic.kind == .topic)
        #expect(topic.code == "")
        #expect(topic.title == "Invented Systems Design")
        #expect(try Self.requestFields("/api/topics", "post") == ["title"])
    }

    @Test func renameSendsTheTitleAlone() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("topic-create")])
        let (client, _) = TestClient.make(transport)
        _ = try await client.renameTopic(id: "70000000-0000-4000-8000-000000000003", title: "Invented Systems Design")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/courses/70000000-0000-4000-8000-000000000003")
        // A topic takes title and archived only: a code or semester for it is refused.
        #expect(try Self.sent(request) == .object(["title": .string("Invented Systems Design")]))
        #expect(try Self.requestFields("/api/courses/{id}", "patch").isSuperset(of: ["title", "archived"]))
    }

    @Test func archivingATopicSendsArchivedAlone() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("topic-create")])
        let (client, _) = TestClient.make(transport)
        _ = try await client.setCourseArchived(id: "70000000-0000-4000-8000-000000000003", true)
        #expect(try Self.sent(transport.requests.first) == .object(["archived": .bool(true)]))
    }

    @Test func topicOrderNamesEveryTopic() async throws {
        let transport = FixtureTransport(bodies: [try Self.body("topic-order")])
        let (client, _) = TestClient.make(transport)
        let ids = ["70000000-0000-4000-8000-000000000003", TopicToleranceTests.topicID, "70000000-0000-4000-8000-000000000002"]
        let topics = try await client.setTopicOrder(ids)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/topic-order")
        #expect(try Self.sent(request) == .object(["topicIds": .array(ids.map(JSONValue.string))]))
        #expect(topics.map(\.id) == ids)
        #expect(topics.map(\.sortOrder) == [1, 2, 3])
        #expect(try Self.requestFields("/api/topic-order", "put") == ["topicIds"])
    }

    @Test func archivingASemesterSendsArchivedAlone() async throws {
        let semester = try #require(try QBankJSON.decoder.decode(JSONValue.self, from: Self.body("semesters"))["semesters"]?.arrayValue?.last)
        let transport = FixtureTransport(bodies: [try JSONEncoder().encode(semester)])
        let (client, _) = TestClient.make(transport)
        let archived = try await client.setSemesterArchived(id: "3d9a9957-5eb2-4949-b1f7-086f1e51ff62", true)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/semesters/3d9a9957-5eb2-4949-b1f7-086f1e51ff62")
        // Its name and dates are left out, so they stay.
        #expect(try Self.sent(request) == .object(["archived": .bool(true)]))
        #expect(archived.archivedAt != nil)
        #expect(try Self.requestFields("/api/semesters/{id}", "patch").contains("archived"))
    }

    @Test func aStudyPageSendsItsPrimerLinkOnlyWhenAsked() async throws {
        let page = try #require(try QBankJSON.decoder.decode(JSONValue.self, from: Self.body("topic"))["exams"]?.arrayValue?.first)
        let body = try JSONEncoder().encode(page)
        let transport = FixtureTransport(bodies: [body, body, body, body])
        let (client, _) = TestClient.make(transport)
        let made = try await client.createCourseExam(courseID: TopicToleranceTests.topicID, name: "Page 1", folderIDs: [], link: .url("https://primer.invalid/cardiac-drugs"))
        _ = try await client.updateCourseExam(id: made.id, name: "Page 1", folderIDs: [], link: .none)
        _ = try await client.updateCourseExam(id: made.id, name: "Page 1", folderIDs: [])
        _ = try await client.createCourseExam(courseID: TopicToleranceTests.topicID, name: "Page 2", folderIDs: [])
        let sent = try transport.requests.map(Self.sent)
        #expect(sent[0]["linkUrl"] == .string("https://primer.invalid/cardiac-drugs"))
        #expect(sent[1]["linkUrl"]?.isNull == true, "null takes it off")
        #expect(sent[2]["linkUrl"] == nil, "left out, the page keeps its link")
        #expect(sent[3]["linkUrl"] == nil, "a course's exam page sends no link")
        #expect(made.linkURL == "https://primer.invalid/cardiac-drugs")
        #expect(try Self.requestFields("/api/courses/{id}/course-exams", "post").contains("linkUrl"))
        #expect(try Self.requestFields("/api/course-exams/{id}", "put").contains("linkUrl"))
    }

    @Test func anExamPageFromBeforePrimerLinksHasNone() throws {
        let course = try Fixture.load("course-with-exams").decodeBody(CourseDetail.self)
        #expect(!course.exams.isEmpty)
        #expect(course.exams.allSatisfy { $0.linkURL == nil })
    }

    @Test func importIntoANewTopicSendsItsName() async throws {
        let transport = try FixtureTransport("import-new-course")
        let (client, _) = TestClient.make(transport)
        _ = try await client.importSet(ImportRequest(source: "{}", title: nil, course: .newTopic(title: "Invented Systems Design"), folder: .unsorted))
        let sent = try Self.sent(transport.requests.first)
        #expect(sent["newTopic"] == .object(["title": .string("Invented Systems Design")]))
        #expect(sent["courseId"] == nil)
        #expect(sent["newCourse"] == nil)
        #expect(try Self.requestFields("/api/imports", "post").isSuperset(of: ["courseId", "newCourse", "newTopic"]))
    }
}
