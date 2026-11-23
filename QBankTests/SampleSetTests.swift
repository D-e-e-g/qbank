import Foundation
import QBankKit
import Testing
@testable import QBank

/// The sample set the app ships with: the file passes the import check cleanly, a new free bank is
/// given it as an ordinary set, and a bank that is not new, or is on the server, is left alone.
/// Invented data only.
@MainActor
struct SampleSetTests {
    private func source() throws -> String {
        try #require(SampleSet.bundledSource(), "the app bundle carries the sample set")
    }

    private func freeApp(bank: LocalBank, sampleSet: String?) -> AppModel {
        let store = InMemorySessionStore(StoredSession(token: TestApp.token, account: .student()))
        let client = QBankClient(
            configuration: APIConfiguration(baseURL: URL(string: "https://stub.invalid")!), transport: StubServer(), sessionStore: store)
        let defaults = TestApp.freshDefaults()
        return AppModel(
            client: client, kind: .free, bank: bank, sampleSet: sampleSet, look: LookStore(defaults: defaults),
            lock: AppLock(defaults: defaults, owner: DebugDeviceOwner(.faceID)), highlighter: HighlighterStore(defaults: defaults),
            aiConsent: AIConsentStore(defaults: defaults), storage: .memory(), connection: Connection())
    }

    // MARK: The file

    @Test func theFilePassesTheImportCheckWithNoWarning() throws {
        let report = ImportChecker.report(for: try source())
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.warnings.isEmpty, "\(report.warnings)")
        #expect(report.ok)
        #expect(report.kind == .practice)
        #expect(report.questionCount == 10)
        #expect(report.formats.map(\.type) == ["single", "sata"], "single answer (true or false is one) and select all that apply")
        #expect(report.formats.map(\.count) == [8, 2])
    }

    @Test func everyQuestionIsAskedAndExplained() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(source().utf8)) as? [String: Any])
        let questions = try #require(file["questions"] as? [[String: Any]])
        let ids = questions.compactMap { $0["id"] as? String }
        #expect(Set(ids).count == questions.count, "each question has its own id")
        for question in questions {
            for field in ["stem", "ask", "rationale", "takeaway"] {
                let text = (question[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                #expect(!text.isEmpty, "\(question["id"] ?? "?") has no \(field)")
            }
        }
        let trueOrFalse = questions.filter { question in
            let choices = (question["options"] as? [[String: Any]])?.compactMap { $0["t"] as? String } ?? []
            return Set(choices) == ["True", "False"]
        }
        #expect(trueOrFalse.count == 2)
    }

    // MARK: Filing it

    @Test func aNewFreeBankIsGivenItAsAnOrdinarySet() async throws {
        let bank = try LocalBank(store: LocalStore.inMemory())
        let app = freeApp(bank: bank, sampleSet: try source())
        let catalog = try await app.client.catalog()
        let topic = try #require(catalog.topics.first)
        #expect(catalog.topics.count == 1 && topic.title == SampleSet.topic && catalog.semesters.isEmpty)
        let course = try await app.client.course(id: topic.id)
        let sets = course.folders.flatMap(\.sets)
        #expect(sets.map(\.title) == ["General knowledge sampler"])
        #expect(sets.first?.questionCount == 10)

        // An ordinary set: the person can delete it, and the sample does not come back.
        let setID = try #require(sets.first?.id)
        let deletion = try await app.client.practiceSetDeletion(id: setID)
        try await app.client.deletePracticeSet(id: setID, confirm: deletion.confirm)
        let relaunched = freeApp(bank: bank, sampleSet: try source())
        #expect(try await relaunched.client.course(id: topic.id).folders.flatMap(\.sets).isEmpty)
    }

    @Test func aBankThatIsNotNewIsLeftAlone() async throws {
        let bank = try LocalBank(store: LocalStore.inMemory())
        let setup = freeApp(bank: bank, sampleSet: nil)
        let made = try await setup.client.createTopic(title: "Pharmacology")
        let before = try await setup.client.catalog()
        let app = freeApp(bank: bank, sampleSet: try source())
        let after = try await app.client.catalog()
        #expect(after == before, "the person's own topic is all there is")
        #expect(try await app.client.course(id: made.id).folders.flatMap(\.sets).isEmpty)
    }

    @Test func aFreeModelAskedForNoSampleStartsEmpty() async throws {
        let app = freeApp(bank: try LocalBank(store: LocalStore.inMemory()), sampleSet: nil)
        let catalog = try await app.client.catalog()
        #expect(catalog.topics.isEmpty && catalog.semesters.isEmpty)
    }

    @Test func anInvitedAccountIsNeverGivenIt() async throws {
        let server = StubServer(["GET /api/semesters": .ok(#"{"semesters":[],"topics":[]}"#)])
        let (app, _) = TestApp.make(server, account: .student())
        _ = try await app.client.catalog()
        #expect(app.kind == .invited)
        #expect(server.calls == ["GET /api/semesters"], "its bank is on the server and nothing is imported into it")
    }
}
