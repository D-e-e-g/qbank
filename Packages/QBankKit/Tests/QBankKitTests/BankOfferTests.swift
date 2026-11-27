import Foundation
import Testing

@testable import QBankKit

/// What adding a set that only this phone has to QBank Cloud sends (`docs/cloud.md`): the set rebuilt
/// as a question file from its rows, as the server rebuilds one, which the import check takes and
/// stores as the same questions; and an import into the course or topic of the same name, beside any
/// set of the same name, never in its place. Invented data only.
@Suite("Offering this phone's sets to QBank Cloud")
struct BankOfferTests {
    /// A set with every field a question file can hoist, and terms.
    static let richFile = Files.make(
        "Cardiac",
        [
            Files.single(
                "Q1",
                extra: [
                    "stem": .string("A person walks in."), "rationale": .string("Because."), "takeaway": .string("Remember this."),
                    "topic": .string("Rhythm"), "cj": .string("Recognize cues"), "need": .string("Physiological"), "diff": .number(3),
                    "wk": .string("Week 2"), "src": .string("Invented notes"), "terms": .array([.string("pulse")]),
                ]),
            Files.single("Q2", right: 2),
        ],
        terms: ["pulse": ["Pulse", "The beat felt at the wrist."]], kind: "practice", description: "Invented.")

    @Test func aSetRebuiltAsAFileComesBackAsTheSameQuestions() async throws {
        let phone = try LocalBankHarness()
        let course = try await phone.makeCourse()
        let set = try #require(try await phone.importFile(Self.richFile, into: course, folderName: "Week 2").body["setId"]?.stringValue)

        let source = try phone.store.read { try BankOffer.questionFile(of: set, in: $0) }

        let checked = ImportChecker.check(source)
        #expect(checked.ok, "\(checked.errors)")
        #expect(checked.warnings == ImportChecker.check(Self.richFile).warnings)
        let cloud = try LocalBankHarness(store: LocalStore.inMemory(), idPrefix: "ff000000")
        let other = try await cloud.makeCourse()
        let added = try await cloud.importFile(source, into: other)
        #expect(added.status == 201)
        let addedSet = try #require(added.body["setId"]?.stringValue)
        let columns = "public_id, position, type, topic, cj, client_need, difficulty, week_label, stem, ask, body, rationale, takeaway, term_keys, source, content_hash"
        #expect(
            try cloud.rows("SELECT \(columns) FROM question WHERE set_id = '\(addedSet)' ORDER BY position")
                == phone.rows("SELECT \(columns) FROM question WHERE set_id = '\(set)' ORDER BY position"),
            "every question, its hash included, is the one on this phone")
        #expect(
            try cloud.rows("SELECT key, term, meaning FROM term WHERE set_id = '\(addedSet)'")
                == phone.rows("SELECT key, term, meaning FROM term WHERE set_id = '\(set)'"))
        #expect(
            try cloud.rows("SELECT title, description, kind FROM practice_set WHERE id = '\(addedSet)'")
                == phone.rows("SELECT title, description, kind FROM practice_set WHERE id = '\(set)'"))
    }

    @Test func theFileLeavesOutAnEmptyFieldAsTheServerDoes() async throws {
        let phone = try LocalBankHarness()
        let topic = try #require(try await phone.send("POST", "/api/topics", .object(["title": .string("Geography")])).body["id"]?.stringValue)
        let set = try #require(try await phone.importFile(Files.make("Capitals", [Files.single("C1")]), into: topic).body["setId"]?.stringValue)

        let source = try phone.store.read { try BankOffer.questionFile(of: set, in: $0) }

        let file = try #require(try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        #expect(Set(file.keys) == ["title", "desc", "kind", "terms", "questions"])
        let question = try #require((file["questions"] as? [[String: Any]])?.first)
        // The import gave the question its folder's name as its week label, which is written as the server writes it.
        #expect(Set(question.keys) == ["id", "type", "ask", "options", "wk"], "no null, empty text or empty list is written: \(source)")
        #expect(question["wk"] as? String == "Unsorted")
    }

    @Test func theSetsOfferedAreReadByIdAndOnlyWhileTheyAreCurrent() async throws {
        let phone = try LocalBankHarness()
        let topic = try #require(try await phone.send("POST", "/api/topics", .object(["title": .string("Geography")])).body["id"]?.stringValue)
        let first = try #require(try await phone.importFile(Files.make("Capitals", [Files.single("C1")]), into: topic, folderName: "Europe").body["setId"]?.stringValue)
        let second = try #require(try await phone.importFile(Files.make("Rivers", [Files.single("R1")]), into: topic).body["setId"]?.stringValue)
        _ = try await phone.importFile(Files.make("Capitals", [Files.single("C2")]), into: topic, decision: "replace")

        let sets = try BankOffer.sets([first, second, "not-a-set"], in: phone.store)

        #expect(sets.map(\.title) == ["Rivers"], "a set replaced since is no longer one of the current sets")
        #expect(sets.first?.place.folder == "Unsorted")
    }

    // MARK: Where an added set goes

    static let catalog = Catalog(
        semesters: [
            Semester(
                id: "s1", number: 1, name: "Semester 1", startsOn: nil, endsOn: nil,
                courses: [
                    course("c-archived", code: "NURS 101", title: "Invented Nursing", archived: true),
                    course("c1", code: "NURS 101", title: "Invented Nursing"),
                ]),
            Semester(
                id: "s3", number: 3, name: "Semester 3", startsOn: nil, endsOn: nil,
                courses: [course("c3-archived", code: "NURS 301", title: "Invented Pharmacology", archived: true)]),
        ],
        topics: [course("t-archived", kind: .topic, title: "History", archived: true), course("t1", kind: .topic, title: "Geography")])

    static func course(_ id: String, kind: CourseKind = .course, code: String = "", title: String, archived: Bool = false) -> CourseSummary {
        CourseSummary(
            id: id, kind: kind, code: code, title: title, sortOrder: 1, archivedAt: archived ? ArchiveWorld.date : nil, questionCount: 0, weekCount: 0,
            reviewCount: 0, answeredCount: 0, fullyRightCount: 0, points: 0, maxPoints: 0)
    }

    @Test(arguments: [
        (BankOffer.PhoneSet.Place(kind: .topic, code: "", title: " geography ", semesterNumber: nil, folder: nil), ImportRequest.Course.existing(id: "t1")),
        (.init(kind: .topic, code: "", title: "History", semesterNumber: nil, folder: nil), .existing(id: "t-archived")),
        (.init(kind: .topic, code: "", title: "Botany", semesterNumber: nil, folder: nil), .newTopic(title: "Botany")),
        (.init(kind: .course, code: "NURS 101", title: "Fundamentals of Nursing", semesterNumber: 1, folder: nil), .existing(id: "c1")),
        (.init(kind: .course, code: "nurs 301", title: "Invented Pharmacology", semesterNumber: 3, folder: nil), .existing(id: "c3-archived")),
        (.init(kind: .course, code: "nurs 101", title: "Invented Nursing", semesterNumber: 1, folder: nil), .existing(id: "c1")),
        (.init(kind: .course, code: "NURS 101", title: "Invented Nursing", semesterNumber: 2, folder: nil), .new(code: "NURS 101", title: "Invented Nursing", semesterNumber: 2)),
        (.init(kind: .course, code: "NURS 102", title: "Invented Nursing", semesterNumber: 1, folder: nil), .new(code: "NURS 102", title: "Invented Nursing", semesterNumber: 1)),
    ])
    func anAddedSetGoesIntoTheCourseOrTopicOfTheSameNameOrANewOne(_ place: BankOffer.PhoneSet.Place, _ expected: ImportRequest.Course) {
        #expect(BankOffer.course(for: place, in: Self.catalog) == expected)
    }

    @Test func anAddedSetIsImportedBesideAnySetOfTheSameNameIntoItsFolder() async throws {
        let phone = try LocalBankHarness()
        let topic = try #require(try await phone.send("POST", "/api/topics", .object(["title": .string("Geography")])).body["id"]?.stringValue)
        let inFolder = try #require(try await phone.importFile(Files.make("Capitals", [Files.single("C1")]), into: topic, folderName: "Europe").body["setId"]?.stringValue)
        let sets = try BankOffer.sets([inFolder], in: phone.store)

        let request = try BankOffer.importRequest(for: try #require(sets.first), from: phone.store, into: Self.catalog)

        #expect(request.course == .existing(id: "t1"))
        #expect(request.folder == .named("Europe"))
        #expect(request.decision == .separate, "an added set never replaces one in QBank Cloud")
        #expect(request.title == nil)
        #expect(ImportChecker.check(request.source).ok)

        let unsorted = try #require(try await phone.importFile(Files.make("Rivers", [Files.single("R1")]), into: topic).body["setId"]?.stringValue)
        let loose = try #require(try BankOffer.sets([unsorted], in: phone.store).first)
        #expect(loose.place.folder == "Unsorted")
        #expect(try BankOffer.importRequest(for: loose, from: phone.store, into: Self.catalog).folder == .unsorted, "Unsorted goes into Unsorted")
    }
}
