import Foundation
import Testing

@testable import QBankKit

/// The bank on the phone against the real server's recordings. A transcript replays equal when
/// every answer matches in status, header and body, with times within the replay's tolerance and
/// ids bound one to one (`TranscriptReplay`).
///
/// The bank serves the catalog (semesters, courses, topics, pages and folders), the sets (import, replace, restore, a set's questions
/// and a course's terms), the study routes (answers, a set's sittings and Start over, Review and the place), deleting and Undo
/// (sets, folders, pages, courses and topics, with Recently deleted) and exams. A transcript is proven whole when every bank request in it is one
/// the bank serves. One that also holds a request a later slice serves (the archive) is proven up to that request, and the
/// request is named in `waiting`, so the day a slice serves it the transcript moves to the whole list. An agent's imports and the
/// admin's reads are not the bank's to answer, so those transcripts are not listed.
@Suite struct LocalBankParityTests {
    /// The paths of the bank, which the phone answers. Everything else is the account, which stays on the server.
    static func isBank(_ request: Fixture.Request) -> Bool {
        [
            "/api/semesters", "/api/courses", "/api/topics", "/api/topic-order", "/api/course-exams", "/api/folders", "/api/practice-sets", "/api/imports",
            "/api/attempts", "/api/exams", "/api/deleted-courses", "/api/me/place",
        ].contains { request.path == $0 || request.path.hasPrefix($0 + "/") }
    }

    /// What the phone answers: the bank's paths, from someone signed in. It does not check the bearer token (a file on the phone is already
    /// the signed-in person's), so a request sent with none belongs to the account and stays on the server.
    static func isAnswered(_ request: Fixture.Request) -> Bool { isBank(request) && request.authorization != nil }

    /// Transcripts that replay whole: every bank request in them is served by this slice.
    static let whole = [
        "deletion-contents", "deletion-courses", "deletion-pages", "organize-catalog", "organize-imports", "practice-continuing", "practice-restoring", "practice-studying", "topics",
    ]

    /// Transcripts that hold a request of a later slice: how many steps come before the first such
    /// request, and what it is. Those steps replay now.
    static let waiting: [String: (step: Int, request: String)] = [:]

    /// Transcripts whose exam asks for sets the server's twin job filed, which the phone has no job to write: how many
    /// steps come before it and what it is. Those steps replay now.
    static let askingForTwins: [String: (step: Int, request: String)] = [
        "twins": (18, "POST /api/courses/c0000000-0000-4000-8000-000000000501/exams")
    ]

    // `organize-folders` is not listed: it holds exams too, but a delete preview in it asks for a page by an id the recording gave to a
    // page made later, which no replay can send, so `LocalBankOrganizeTests` replays it up to its exams with that one step left out.

    @Test(arguments: whole)
    func replaysWhole(_ name: String) async throws {
        let transcript = try Transcript.load(name)
        let harness = try LocalBankHarness()
        let differences = try await TranscriptReplay.run(transcript, over: harness.bank, hooks: harness.hooks(serves: Self.isAnswered))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
        #expect(transcript.exchanges.filter { Self.isBank($0.request) }.allSatisfy { harness.bank.serves($0.request.method, path: $0.request.path) })
    }

    @Test(arguments: waiting.keys.sorted())
    func replaysUpToTheFirstRequestOfALaterSlice(_ name: String) async throws {
        let transcript = try Transcript.load(name)
        let harness = try LocalBankHarness()
        let expected = try #require(Self.waiting[name])
        let first = try #require(
            transcript.steps.firstIndex {
                guard case .request(let exchange) = $0 else { return false }
                return Self.isBank(exchange.request) && !harness.bank.serves(exchange.request.method, path: exchange.request.path)
            })
        #expect(first == expected.step)
        if case .request(let exchange) = transcript.steps[first] { #expect("\(exchange.request.method) \(exchange.request.path)" == expected.request) }
        let prefix = Transcript(recordedFrom: transcript.recordedFrom, world: transcript.world, steps: Array(transcript.steps[..<first]))
        let differences = try await TranscriptReplay.run(prefix, over: harness.bank, hooks: harness.hooks(serves: Self.isAnswered))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
    }

    @Test(arguments: askingForTwins.keys.sorted())
    func replaysUpToTheExamThatAsksForTwins(_ name: String) async throws {
        let transcript = try Transcript.load(name)
        let harness = try LocalBankHarness()
        let expected = try #require(Self.askingForTwins[name])
        guard case .request(let exchange) = transcript.steps[expected.step] else {
            Issue.record("step \(expected.step) is not a request")
            return
        }
        #expect("\(exchange.request.method) \(exchange.request.path)" == expected.request)
        #expect(harness.bank.serves(exchange.request.method, path: exchange.request.path))
        let prefix = Transcript(recordedFrom: transcript.recordedFrom, world: transcript.world, steps: Array(transcript.steps[..<expected.step]))
        let differences = try await TranscriptReplay.run(prefix, over: harness.bank, hooks: harness.hooks(serves: Self.isAnswered))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
    }
}
