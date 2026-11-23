import Foundation
import Testing

@testable import QBankKit

/// The exam steps of `deletion-contents`, the one recording that deletes a past exam, replayed against the
/// bank on the phone: an exam started over a folder whose set was deleted, answered and finished, its
/// delete preview taken with its folder deleted, its delete, and its Undo.
///
/// Deleting a set or a folder is the deletion slice's, which this bank does not serve yet. Those two deletes
/// are made here by hand in the store, as the recording made them, so the exam steps meet the state the
/// recording had; the steps between are left out. The day the bank serves them the whole transcript
/// replays (`LocalBankParityTests`) and this test only repeats part of it.
@Suite struct LocalBankExamParityTests {
    /// The bank, except that a delete of a set or a folder is written straight to the store.
    private final class HandDeletes: HTTPTransport, @unchecked Sendable {
        private let harness: LocalBankHarness

        init(_ harness: LocalBankHarness) { self.harness = harness }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard request.httpMethod == "DELETE", let url = request.url else { return try await harness.bank.send(request) }
            let time = QBankJSON.formatDate(harness.now)
            let mark = "dd000000-0000-4000-8000-000000000001"
            let id = url.lastPathComponent
            if url.path.hasPrefix("/api/practice-sets/") {
                try harness.store.run(
                    "UPDATE practice_set SET deleted_at = ?, deletion_id = ? WHERE lineage_id = (SELECT lineage_id FROM practice_set WHERE id = ?) AND deleted_at IS NULL",
                    [.text(time), .text(mark), .text(id)])
            } else if url.path.hasPrefix("/api/folders/") {
                try harness.store.run("UPDATE practice_set SET deleted_at = ?, deletion_id = ? WHERE folder_id = ? AND deleted_at IS NULL", [.text(time), .text(mark), .text(id)])
                try harness.store.run("UPDATE folder SET deleted_at = ?, deletion_id = ? WHERE id = ?", [.text(time), .text(mark), .text(id)])
            } else {
                return try await harness.bank.send(request)
            }
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])))
        }
    }

    @Test func aPastExamIsStartedDeletedAndBroughtBackAsTheServerDidIt() async throws {
        let full = try Transcript.loadWithImportDrift("deletion-contents")
        // Setup and answers (0 to 20); a set deleted, and its write that moves the delete back (22, 23); the exam, its answers
        // and its end (24 to 28); a set added to the folder (36); the folder deleted (39); the exam's preview, delete and Undo (41, 42, 46).
        let picked = Array(0..<21) + [22, 23] + Array(24...28) + [36, 39, 41, 42, 46]
        let names = picked.compactMap { index -> String? in if case .request(let exchange) = full.steps[index] { exchange.name } else { nil } }
        #expect(names.filter { $0.hasPrefix("exam-") } == ["exam-delete-preview", "exam-delete", "exam-undo-delete"])
        let transcript = Transcript(recordedFrom: full.recordedFrom, world: full.world, steps: picked.map { full.steps[$0] })
        let harness = try LocalBankHarness()
        let differences = try await TranscriptReplay.run(transcript, over: HandDeletes(harness), hooks: harness.hooks(serves: LocalBankParityTests.isAnswered))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
    }
}
