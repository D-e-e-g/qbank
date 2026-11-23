import Foundation
import Testing

@testable import QBankKit

/// The organize transcript for folders and pages, replayed over the state its four imports left.
///
/// `organize-folders` begins with four imports, which a later slice serves. This test writes into
/// the store what those imports made (the sets, their questions and their folders, with the ids and
/// times the recording shows) and replays the rest of the transcript that this slice serves: pages,
/// folders, moving a set, ordering, and the course as it reads afterwards. The recorded ids of that
/// state are the client's own in the replay, so they are sent as recorded. The delete preview of a page
/// that is not there, and the exams the recording took at its end, belong to later slices and are left out.
@Suite struct LocalBankOrganizeTests {
    /// The steps of `organize-folders`: the sign-in, the semester and the course, then the imports, the pages and folders, and the exams at its end.
    private static let served = 7..<30
    /// The one request among them that a later slice serves: the delete preview of a page that is not there.
    private static let deletion = 13

    @Test func pagesAndFoldersReplayEqualOverTheImportedState() async throws {
        let transcript = try Transcript.load("organize-folders")
        let harness = try LocalBankHarness()
        try seed(harness.store, from: transcript)
        let steps = Self.served.filter { $0 != Self.deletion }.map { transcript.steps[$0] }
        let tail = Transcript(recordedFrom: transcript.recordedFrom, world: transcript.world, steps: steps)
        #expect(tail.exchanges.allSatisfy { harness.bank.serves($0.request.method, path: $0.request.path) })
        guard case .request(let skipped) = transcript.steps[Self.deletion] else { throw LocalBankHarnessError.missing }
        #expect(skipped.name == "course-exam-not-found" && skipped.request.path.hasSuffix("/delete-preview"))
        let differences = try await TranscriptReplay.run(tail, over: harness.bank, hooks: harness.hooks())
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
    }

    // MARK: The state the skipped steps made

    private func seed(_ store: LocalStore, from transcript: Transcript) throws {
        let answers = transcript.exchanges.map(\.response.body)
        let semester = answers[1]
        let course = answers[2]
        let imports = answers[3...6]
        let detail = try #require(transcript.exchanges[29].response.body["weeks"]?.arrayValue)
        let created = "2026-11-22T20:05:36.000Z"
        func text(_ value: JSONValue?) throws -> String { try #require(value?.stringValue) }

        try store.transaction { tx in
            try tx.execute(
                "INSERT INTO semester (id, number, name, created_at) VALUES (?, 1, ?, ?)",
                [.text(try text(semester["id"])), .text(try text(semester["name"])), .text(created)])
            try tx.execute(
                "INSERT INTO course (id, semester_id, kind, code, title, sort_order, created_at) VALUES (?, ?, 'course', ?, ?, 1, ?)",
                [.text(try text(course["id"])), .text(try text(semester["id"])), .text(try text(course["code"])), .text(try text(course["title"])), .text(created)])
            var folders: [String] = []
            for imported in imports {
                let folder = try text(imported["folderId"])
                if !folders.contains(folder) {
                    folders.append(folder)
                    try tx.execute(
                        "INSERT INTO folder (id, course_id, name, sort_order, created_at) VALUES (?, ?, ?, ?, ?)",
                        [.text(folder), .text(try text(course["id"])), .text(try text(imported["folderName"])), .integer(Int64(folders.count)), .text(created)])
                }
            }
            let sets = detail.flatMap { $0["sets"]?.arrayValue ?? [] }
            for (index, set) in sets.enumerated() {
                let id = try text(set["id"])
                let imported = try #require(imports.first { $0["setId"]?.stringValue == id })
                try tx.execute(
                    """
                    INSERT INTO practice_set (id, course_id, lineage_id, title, description, week_label, folder_id, sort_order, imported_at, file_hash, stats, is_current, kind)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'hash', '{}', 1, 'practice')
                    """,
                    [
                        .text(id), .text(try text(course["id"])), .text(String(format: "5e100000-0000-4000-8000-%012x", index)), .text(try text(set["title"])),
                        .text(try text(set["description"])), .text(try text(imported["weekLabel"])), .text(try text(imported["folderId"])), .integer(Int64(index + 1)),
                        .text(try text(set["importedAt"])),
                    ])
                for (position, question) in try #require(set["questionIds"]?.arrayValue).enumerated() {
                    try tx.execute(
                        """
                        INSERT INTO question (id, set_id, lineage_id, public_id, position, type, topic, week_label, stem, ask, body, rationale, takeaway, term_keys, content_hash)
                        VALUES (?, ?, ?, ?, ?, 'single', '', ?, 'Stem', 'Ask', '{}', 'Why', 'Take', '[]', 'hash')
                        """,
                        [
                            .text(try text(question)), .text(id), .text(String(format: "5e200000-0000-4000-8000-%012x", index * 10 + position)), .text("Q\(position + 1)"),
                            .integer(Int64(position + 1)), .text(try text(imported["weekLabel"])),
                        ])
                }
            }
        }
    }
}
