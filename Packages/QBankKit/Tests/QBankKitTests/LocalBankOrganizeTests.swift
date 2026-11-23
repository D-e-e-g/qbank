import Foundation
import Testing

@testable import QBankKit

/// The organize transcript for folders and pages, replayed whole over the imports it begins with.
///
/// `organize-folders` begins with four imports, then makes pages and folders, moves a set and orders
/// folders, and ends with two exams. The bank serves every step but two kinds: the delete preview of a
/// page that is not there, and the exams at its end, which the exam family serves. The preview is served, but the recording asks for
/// the page by an id it gave to a page made in the next step, which a replay sends as it is and then cannot bind to the page the bank
/// makes; `LocalBankDeleteTests` proves its answer against the recorded fixture. Both are left out, and the rest replays in order
/// with no difference, so the folders and pages are proven over the state the bank's own imports made.
@Suite struct LocalBankOrganizeTests {
    /// The steps the bank serves: everything before the exams at the end, but for the one delete preview.
    private static let served = 0..<30
    private static let deletion = 13

    @Test func pagesAndFoldersReplayEqualOverTheBanksOwnImports() async throws {
        let transcript = try Transcript.loadWithImportDrift("organize-folders")
        let harness = try LocalBankHarness()
        let steps = Self.served.filter { $0 != Self.deletion }.map { transcript.steps[$0] }
        let whole = Transcript(recordedFrom: transcript.recordedFrom, world: transcript.world, steps: steps)
        #expect(whole.exchanges.filter { LocalBankParityTests.isBank($0.request) }.allSatisfy { harness.bank.serves($0.request.method, path: $0.request.path) })
        guard case .request(let skipped) = transcript.steps[Self.deletion] else { throw LocalBankHarnessError.missing }
        #expect(skipped.name == "course-exam-not-found" && skipped.request.path.hasSuffix("/delete-preview"))
        let differences = try await TranscriptReplay.run(whole, over: harness.bank, hooks: harness.hooks(serves: LocalBankParityTests.isBank))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
    }
}
