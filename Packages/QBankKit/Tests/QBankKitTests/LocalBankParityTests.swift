import Foundation
import Testing

@testable import QBankKit

/// The bank on the phone against the real server's recordings. A transcript replays equal when
/// every answer matches in status, header and body, with times within the replay's tolerance and
/// ids bound one to one (`TranscriptReplay`).
///
/// This slice serves the catalog: semesters, courses, topics, pages and folders. A transcript is
/// proven whole when every bank request in it is one this slice serves. One that also holds a
/// request a later slice serves (import, answers, exams, deletion, the place, the archive) is
/// proven up to that request, and the request is named in `waiting`, so the day a slice serves it
/// the transcript moves to the whole list.
@Suite struct LocalBankParityTests {
    /// The paths of the bank, which the phone answers. Everything else is the account, which stays on the server.
    static func isBank(_ request: Fixture.Request) -> Bool {
        [
            "/api/semesters", "/api/courses", "/api/topics", "/api/topic-order", "/api/course-exams", "/api/folders", "/api/practice-sets", "/api/imports",
            "/api/attempts", "/api/exams", "/api/deleted-courses", "/api/me/place",
        ].contains { request.path == $0 || request.path.hasPrefix($0 + "/") }
    }

    /// Transcripts that replay whole: every bank request in them is served by this slice.
    static let whole = ["organize-catalog"]

    /// Transcripts that hold a request of a later slice: how many steps come before the first such
    /// request, and what it is. Those steps replay now.
    static let waiting: [String: (step: Int, request: String)] = [
        "organize-folders": (3, "POST /api/imports"),
        "organize-imports": (6, "POST /api/imports/check"),
        "topics": (6, "POST /api/imports"),
    ]

    @Test(arguments: whole)
    func replaysWhole(_ name: String) async throws {
        let transcript = try Transcript.load(name)
        let harness = try LocalBankHarness()
        let differences = try await TranscriptReplay.run(transcript, over: harness.bank, hooks: harness.hooks(serves: Self.isBank))
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
        let differences = try await TranscriptReplay.run(prefix, over: harness.bank, hooks: harness.hooks(serves: Self.isBank))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
    }
}
