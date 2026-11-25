import Foundation
import Testing

@testable import QBankKit

/// Filing a sample set into a new bank: it goes in through the import as an ordinary set, once, and a bank that has ever held anything is left alone. Invented data only.
@Suite struct SampleSetFilingTests {
    private let file = Files.make("Invented sampler", [Files.single("A1"), Files.single("A2")])

    private func count(_ harness: LocalBankHarness, _ table: String) throws -> Int {
        try harness.store.run("SELECT count(*) AS n FROM \(table)")[0].int("n") ?? 0
    }

    @Test func aNewBankGetsTheSetInATopicMadeForIt() throws {
        let harness = try LocalBankHarness()
        #expect(try harness.bank.fileSampleSet(file, inTopic: "Invented topic"))
        let topics = try harness.store.run("SELECT * FROM course")
        #expect(topics.count == 1 && topics[0].text("kind") == "topic" && topics[0].text("title") == "Invented topic")
        let sets = try harness.store.run("SELECT * FROM practice_set")
        #expect(sets.count == 1 && sets[0].text("title") == "Invented sampler" && sets[0].text("week_label") == "Unsorted" && sets[0].bool("is_current") == true)
        #expect(sets[0].text("course_id") == topics[0].text("id") && sets[0].text("deleted_at") == nil)
        #expect(try count(harness, "question") == 2)
        #expect(try count(harness, "semester") == 0)
    }

    @Test func itIsFiledOnceEvenWhenThePersonDeletesEverything() async throws {
        let harness = try LocalBankHarness()
        #expect(try harness.bank.fileSampleSet(file, inTopic: "Invented topic"))
        let topic = try #require(try harness.store.run("SELECT id FROM course")[0].text("id"))
        let preview = try await harness.send("GET", "/api/courses/\(topic)/delete-preview")
        let confirm = try #require(preview.body["confirm"]?.stringValue)
        #expect(try await harness.send("DELETE", "/api/courses/\(topic)?confirm=\(confirm)").status == 204)
        #expect(try harness.store.run("SELECT * FROM course WHERE deleted_at IS NULL").isEmpty, "the person has no topic now")
        let before = try harness.rows("SELECT * FROM practice_set")
        #expect(try harness.bank.fileSampleSet(file, inTopic: "Invented topic") == false)
        #expect(try harness.rows("SELECT * FROM practice_set") == before)
        #expect(try harness.rows("SELECT * FROM course").count == 1)
    }

    @Test func aBankWithOnlyASemesterOrOnlyATopicIsLeftAlone() async throws {
        for made in ["semester", "topic"] {
            let harness = try LocalBankHarness()
            let answer =
                made == "semester"
                ? try await harness.send("POST", "/api/semesters", .object(["number": .number(1)]))
                : try await harness.send("POST", "/api/topics", .object(["title": .string("Invented")]))
            #expect(answer.status == 201)
            let before = try [harness.rows("SELECT * FROM semester"), harness.rows("SELECT * FROM course"), harness.rows("SELECT * FROM practice_set")]
            #expect(try harness.bank.fileSampleSet(file, inTopic: "Invented topic") == false)
            let after = try [harness.rows("SELECT * FROM semester"), harness.rows("SELECT * FROM course"), harness.rows("SELECT * FROM practice_set")]
            #expect(after == before, "a bank with only a \(made) is not new")
        }
    }

    @Test func aBankWithASetAlreadyImportedIsLeftAlone() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        #expect(try await harness.importFile(file, into: course).status == 201)
        let before = try harness.rows("SELECT * FROM practice_set")
        #expect(try harness.bank.fileSampleSet(file, inTopic: "Invented topic") == false)
        #expect(try harness.rows("SELECT * FROM practice_set") == before)
        #expect(try harness.rows("SELECT * FROM course WHERE kind = 'topic'").isEmpty)
    }

    @Test func aFileTheImportRefusesFilesNothing() throws {
        let harness = try LocalBankHarness()
        #expect(throws: SampleSetError.self) { try harness.bank.fileSampleSet("not json", inTopic: "Invented topic") }
        #expect(try count(harness, "course") == 0 && count(harness, "practice_set") == 0, "a refused file leaves the bank new")
        #expect(try harness.bank.fileSampleSet(file, inTopic: "Invented topic"))
    }
}
