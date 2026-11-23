import Foundation
import Synchronization
import Testing

@testable import QBankKit

/// A bank on the phone for a test: an in-memory store, a clock the test sets and ids that count up,
/// so every run answers the same.
final class LocalBankHarness: Sendable {
    let store: LocalStore
    let bank: LocalBank
    private final class State: Sendable {
        let time = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let next = Mutex(0)
    }

    private let state = State()

    init() throws {
        let store = try LocalStore.inMemory()
        let state = self.state
        self.store = store
        bank = LocalBank(
            store: store,
            clock: { state.time.withLock { $0 } },
            ids: {
                state.next.withLock { number in
                    number += 1
                    return String(format: "ee000000-0000-4000-8000-%012x", number)
                }
            })
    }

    func set(_ date: Date) { state.time.withLock { $0 = date } }

    /// What the replay hands the engine: its clock set to each step's recorded time, and which requests it serves.
    func hooks(serves: @escaping @Sendable (Fixture.Request) -> Bool = { _ in true }) -> TranscriptReplay.Hooks {
        TranscriptReplay.Hooks(
            clock: { [self] date in set(date) }, serves: serves,
            // The server draws the order of a Review list's questions at random.
            shuffles: { $0.path.hasSuffix("/review/practice") })
    }

    /// Sends one request and returns its status and JSON body.
    func send(_ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> (status: Int, body: JSONValue) {
        var request = URLRequest(url: try #require(URL(string: "https://qbank.invalid\(path)")))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await bank.send(request)
        return (response.statusCode, data.isEmpty ? .null : try JSONDecoder().decode(JSONValue.self, from: data))
    }
}

enum LocalBankHarnessError: Error { case missing }
