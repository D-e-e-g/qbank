import Foundation
import Testing

@testable import QBankKit

@Suite struct LocalBankWriteTimeTests {
    /// Replay the successful and refused writes through the real router. Compare every row before
    /// and after each request, including writes made by an exam GET or by a cascading delete or Undo.
    @Test func everyWriteRouteStampsOnlyTheRowsItChanges() async throws {
        var covered = Set<String>()
        for name in LocalBankParityTests.whole + ["organize-folders"] {
            let harness = try LocalBankHarness()
            let transport = CheckingWrites(harness)
            var transcript = try Transcript.load(name)
            if name == "organize-folders" {
                // This preview names an id that the recorder later gave to a newly created page.
                let steps = transcript.steps.filter { step in
                    if case .request(let exchange) = step { return exchange.name != "course-exam-not-found" }
                    return true
                }
                transcript = Transcript(recordedFrom: transcript.recordedFrom, world: name, steps: steps)
            }
            let differences = try await TranscriptReplay.run(transcript, over: transport, hooks: harness.hooks(serves: LocalBankParityTests.isAnswered))
            #expect(differences.isEmpty, "\(name): \(differences)")
            covered.formUnion(await transport.successful)
        }
        let routes = try LocalBankHarness().bank.router.routes.filter(\.writes)
        #expect(covered == Set(routes.map(Self.name)))
    }

    private static func name(_ route: BankRoute) -> String {
        let parts = route.segments.map { segment in
            switch segment {
            case .literal(let value): value
            case .parameter(let key): ":\(key)"
            }
        }
        return "\(route.method) /\(parts.joined(separator: "/"))"
    }

    private actor CheckingWrites: HTTPTransport {
        let harness: LocalBankHarness
        var successful = Set<String>()

        init(_ harness: LocalBankHarness) { self.harness = harness }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let route = try #require(harness.bank.router.find(request.httpMethod ?? "GET", path: request.url?.path ?? "")?.route)
            guard route.writes else { return try await harness.bank.send(request) }
            let before = try snapshot()
            let result = try await harness.bank.send(request)
            let routeName = LocalBankWriteTimeTests.name(route)
            if (200..<300).contains(result.1.statusCode) { successful.insert(routeName) }
            let now = StoreValue.text(QBankJSON.formatDate(harness.now))
            for (table, rows) in try snapshot() {
                for (id, row) in rows {
                    let old = before[table]?[id]
                    let changed = row.columns.contains { $0 != "updated_at" && row[$0] != old?[$0] }
                    let expected = changed ? now : old?["updated_at"]
                    #expect(row["updated_at"] == expected, "\(routeName): \(table) \(id)")
                }
            }
            return result
        }

        private func snapshot() throws -> [String: [String: StoreRow]] {
            try harness.store.read { tx in
                var snapshot: [String: [String: StoreRow]] = [:]
                for table in ["semester", "course", "course_exam", "folder", "practice_set", "study_session"] {
                    let rows = try tx.rows("SELECT * FROM \(table)")
                    snapshot[table] = Dictionary(uniqueKeysWithValues: rows.map { ($0.string("id"), $0) })
                }
                return snapshot
            }
        }
    }
}
