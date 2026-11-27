import Foundation
import Testing

@testable import QBankKit

/// A bank counted as the person counts it, for the screens of a move between this phone and QBank
/// Cloud, beside the twelve tables the move itself compares. Invented data only.
struct BankSummaryTests {
    @Test func onlyTheSetsThePersonCanOpenAreCountedWithTheirQuestionsAndEveryAnswer() async throws {
        let bank = try LocalBankHarness()
        let topic = try #require(try await bank.send("POST", "/api/topics", .object(["title": .string("Geography")])).body["id"]?.stringValue)
        // Capitals, replaced: its earlier version is kept for Restore, and is not one of the person's sets.
        _ = try await bank.importFile(Files.make("Capitals", [Files.single("C1"), Files.single("C2")]), into: topic, folderName: "Europe")
        let capitals = try await bank.importFile(Files.make("Capitals", [Files.single("C1"), Files.single("C3"), Files.single("C4")]), into: topic, folderName: "Europe", decision: "replace")
        #expect(capitals.status == 201)
        _ = try await bank.importFile(Files.make("Lakes", [Files.single("L1")]), into: topic, folderName: "Europe")
        // Rivers, in a folder that was deleted: in Recently deleted, not one of the person's sets.
        let rivers = try await bank.importFile(Files.make("Rivers", [Files.single("R1"), Files.single("R2")]), into: topic, folderName: "Asia")
        let asia = try #require(rivers.body["folderId"]?.stringValue)
        let preview = try await bank.send("GET", "/api/folders/\(asia)/delete-preview")
        #expect(try await bank.send("DELETE", "/api/folders/\(asia)?confirm=\(preview.body["confirm"]?.stringValue ?? "")").status == 204)
        // One answer, to the current Capitals.
        let setID = try #require(capitals.body["setId"]?.stringValue)
        let question = try #require(try bank.store.read { try $0.rows("SELECT id FROM question WHERE set_id = ? ORDER BY position LIMIT 1", [.text(setID)]) }.first?.text("id"))
        let answered = try await bank.send(
            "POST", "/api/attempts",
            .object([
                "clientAttemptId": .string(StudySet.attemptID(1)), "questionId": .string(question),
                "response": .object(["type": .string("single"), "choice": .number(0)]), "guessed": .bool(false),
            ]))
        #expect(answered.status == 201)

        #expect(try BankSummary.of(bank.store) == BankSummary(sets: 2, questions: 4, answers: 1), "the current Capitals and Lakes, and their questions")
        let counts = try BankArchive.counts(of: bank.store)
        #expect(counts["practiceSets"] == 4, "the move still compares every row: the earlier version and the deleted set too")
        #expect(counts["questions"] == 8)
    }

    @Test func anEmptyBankCountsNothing() throws {
        #expect(try BankSummary.of(LocalStore.inMemory()) == BankSummary(sets: 0, questions: 0, answers: 0))
    }
}
