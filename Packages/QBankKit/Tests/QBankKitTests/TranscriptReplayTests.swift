import Foundation
import Synchronization
import Testing

@testable import QBankKit

/// The replay harness (`Support/TranscriptReplay.swift`) proven against the recordings themselves:
/// every transcript replays against itself, and against itself with ids of an engine's own, with no
/// difference; a wrong answer fails with where it is wrong; and only times within the tolerance,
/// ids and tokens bound one to one, and the steps an engine does not serve are let through.
@Suite("Contract: replaying the transcripts")
struct TranscriptReplayTests {
    static let worlds: [String] = (try? Transcript.names()) ?? []

    /// Replays `transcript`'s requests against a recording, which has no way to make a write.
    private func replay(_ transcript: Transcript, against recording: Transcript, hooks: TranscriptReplay.Hooks = .init(write: { _ in })) async throws -> [TranscriptReplay.Difference] {
        try await TranscriptReplay.run(transcript, over: TranscriptTransport(recording), hooks: hooks)
    }

    // MARK: The recordings themselves

    @Test func theTranscriptsAreThere() {
        #expect(Self.worlds.count >= 25)
    }

    /// The proof that the harness itself is right: sending a transcript's own requests to a server
    /// that answers with its own answers finds no difference, in every world.
    @Test(arguments: worlds) func aTranscriptReplaysAgainstItself(world: String) async throws {
        let transcript = try Transcript.load(world)
        let recording = TranscriptTransport(transcript)
        let differences = try await TranscriptReplay.run(transcript, over: recording, hooks: .init(write: { _ in }))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
        #expect(recording.answered == transcript.exchanges.count)
    }

    /// An engine makes its own ids. Against a recording whose every id the server made is another,
    /// the replay binds each to the recorded one and sends the engine's in every later path, query,
    /// body and write, while the client's own ids are sent as recorded.
    @Test(arguments: worlds) func aTranscriptReplaysAgainstItselfWithIdsOfAnEnginesOwn(world: String) async throws {
        let transcript = try Transcript.load(world)
        let engine = try transcript.withEngineIds()
        let writes = Mutex<[String]>([])
        let recording = TranscriptTransport(engine)
        let differences = try await TranscriptReplay.run(transcript, over: recording, hooks: .init(write: { write in writes.withLock { $0.append(write.id) } }))
        #expect(differences.isEmpty, "\(differences.map(\.description).joined(separator: "\n"))")
        #expect(recording.answered == transcript.exchanges.count)
        #expect(writes.withLock { $0 } == engine.steps.compactMap { if case .write(let write) = $0 { write.id } else { nil } })
    }

    /// The renaming above reaches every place an id is sent, so the replay that passes it translates each.
    @Test func theEngineIdsReachAPathAQueryABodyAndAWriteAndLeaveTheClientsOwn() throws {
        let transcript = try Transcript.load("practice-studying")
        let engine = try transcript.withEngineIds()
        let pairs = zip(transcript.exchanges, engine.exchanges).map { ($0.request, $1.request) }
        #expect(pairs.contains { $0.path != $1.path })
        #expect(pairs.contains { $0.query != $1.query })
        #expect(pairs.contains { $0.body != $1.body && $0.method == "POST" })
        #expect(zip(transcript.steps, engine.steps).contains { if case .write(let one) = $0, case .write(let other) = $1 { one.id != other.id } else { false } })
        let clientAttempts = pairs.compactMap { $0.0.body?["clientAttemptId"]?.stringValue }
        #expect(!clientAttempts.isEmpty)
        #expect(clientAttempts == pairs.compactMap { $0.1.body?["clientAttemptId"]?.stringValue })
    }

    /// The recorder holds the server's clock while it answers, and fails a recording in which the
    /// server still stamped a time later than the tolerance after taking the request
    /// (`TIME_TOLERANCE_MS` in `test/record-contract/world.ts`), so the committed ones hold none.
    /// The transcript does not keep when an answer came back, so the next step's time bounds it here.
    @Test func everyTimeStampedWhileAnsweringIsWithinTheToleranceOfTheStep() throws {
        for transcript in try Transcript.all() {
            for (index, step) in transcript.steps.enumerated() {
                guard case .request(let exchange) = step else { continue }
                let next = transcript.steps.dropFirst(index + 1).first.map(\.at) ?? exchange.at.addingTimeInterval(1)
                for text in exchange.response.body.strings {
                    guard let time = TranscriptReplay.time(text), time >= exchange.at, time < next else { continue }
                    #expect(time.timeIntervalSince(exchange.at) <= TranscriptReplay.timeTolerance, "\(transcript.world) step \(index): \(text) was stamped after \(QBankJSON.formatDate(exchange.at))")
                }
            }
        }
    }

    @Test func everyTranscriptIsFromThePinnedCommit() throws {
        let url = try #require(Bundle.module.url(forResource: "pin", withExtension: "json", subdirectory: "Fixtures"))
        let pin = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))["commit"]?.stringValue)
        for transcript in try Transcript.all() {
            #expect(transcript.recordedFrom == pin, "\(transcript.world) was recorded from \(transcript.recordedFrom)")
        }
    }

    /// A world's name is its file's name, and the recording's tokens are placeholders as in the fixtures.
    @Test func transcriptsAreNamedAndHoldOnlyPlaceholderTokens() throws {
        for name in Self.worlds {
            let transcript = try Transcript.load(name)
            #expect(transcript.world == name)
            for exchange in transcript.exchanges {
                if let authorization = exchange.request.authorization {
                    #expect(authorization.hasPrefix("Bearer synthetic-"), "\(name): \(exchange.name ?? exchange.request.path)")
                }
                if let token = exchange.response.body["token"]?.stringValue {
                    #expect(token.hasPrefix("synthetic-"), "\(name): \(exchange.name ?? exchange.request.path)")
                }
            }
        }
    }

    /// Every fixture is a named exchange of exactly one transcript, answered with the same status, and no
    /// transcript names an exchange that is not a fixture. The two come from separate recordings of the
    /// same commit, so their times, `confirm` tokens and the order the server shuffles an exam in differ.
    @Test func everyFixtureIsOneNamedExchangeOfATranscript() throws {
        var statuses: [String: Int] = [:]
        for transcript in try Transcript.all() {
            for exchange in transcript.exchanges {
                guard let name = exchange.name else { continue }
                #expect(statuses[name] == nil, "\(name) is in two transcripts")
                statuses[name] = exchange.response.status
            }
        }
        let fixtures = try Fixture.all()
        #expect(Set(fixtures.map(\.name)) == Set(statuses.keys))
        for fixture in fixtures {
            #expect(statuses[fixture.name] == fixture.response.status, "\(fixture.name)")
        }
    }

    // MARK: A wrong answer fails

    /// Each change to one answer of a world, and where the replay says the answer went wrong.
    private struct Wrong: CustomTestStringConvertible {
        let what: String
        let world: String
        let exchange: String
        let path: String
        let change: @Sendable (Fixture.Response) -> Fixture.Response

        var testDescription: String { what }
    }

    private static let wrongAnswers: [Wrong] = [
        Wrong(what: "a different status", world: "practice-studying", exchange: "attempt-conflict", path: "status") {
            Fixture.Response(status: 400, headers: $0.headers, body: $0.body)
        },
        Wrong(what: "a different sentence", world: "practice-studying", exchange: "attempt-conflict", path: "body.message") {
            $0.with("message") { .string("\($0?.stringValue ?? "") ") }
        },
        Wrong(what: "a different error code", world: "practice-studying", exchange: "attempt-conflict", path: "body.error") {
            $0.with("error") { _ in .string("attempt_replayed") }
        },
        Wrong(what: "a key left out", world: "practice-studying", exchange: "attempt-conflict", path: "body.message") {
            $0.with("message") { _ in nil }
        },
        Wrong(what: "a key added", world: "practice-studying", exchange: "attempt-conflict", path: "body.detail") {
            $0.with("detail") { _ in .string("extra") }
        },
        Wrong(what: "a number off by one", world: "practice-studying", exchange: "attempt-saved", path: "body.maxPoints") {
            $0.with("maxPoints") { .number(($0.flatMap(\.number) ?? 0) + 1) }
        },
        Wrong(what: "a number as text", world: "practice-studying", exchange: "attempt-saved", path: "body.points") {
            $0.with("points") { _ in .string("0") }
        },
        Wrong(what: "a flag flipped", world: "practice-studying", exchange: "attempt-saved", path: "body.inReview") {
            $0.with("inReview") { .bool(!($0 == .bool(true))) }
        },
        Wrong(what: "a null that holds a value", world: "practice-studying", exchange: "attempt-saved", path: "body.pointsText") {
            $0.with("pointsText") { _ in .string("0 of 1") }
        },
        Wrong(what: "a value that is null", world: "practice-studying", exchange: "attempt-saved", path: "body.label") {
            $0.with("label") { _ in .null }
        },
        Wrong(what: "one list item too few", world: "practice-studying", exchange: "course", path: "body.folders") {
            $0.with("folders") { .array(Array(($0?.arrayValue ?? []).dropLast())) }
        },
        Wrong(what: "a changed item in a list", world: "practice-studying", exchange: "course", path: "body.folders[0].name") {
            $0.with("folders") { folders in
                .array((folders?.arrayValue ?? []).enumerated().map { $0.offset == 0 ? $0.element.with("name") { _ in .string("Week 9") } : $0.element })
            }
        },
        Wrong(what: "a time a day out", world: "practice-studying", exchange: "attempt-saved", path: "body.answeredAt") {
            $0.with("answeredAt") { .string(Self.shifted($0, by: 86400)) }
        },
        Wrong(what: "a time just past the tolerance", world: "practice-studying", exchange: "attempt-saved", path: "body.answeredAt") {
            $0.with("answeredAt") { .string(Self.shifted($0, by: TranscriptReplay.timeTolerance + 0.005)) }
        },
        Wrong(what: "a time that is not one", world: "practice-studying", exchange: "attempt-saved", path: "body.answeredAt") {
            $0.with("answeredAt") { _ in .string("yesterday") }
        },
        Wrong(what: "a time that is missing", world: "practice-studying", exchange: "attempt-saved", path: "body.answeredAt") {
            $0.with("answeredAt") { _ in .null }
        },
        Wrong(what: "a missing Retry-After", world: "account-locked", exchange: "account-delete-locked", path: "headers.retry-after") {
            Fixture.Response(status: $0.status, headers: [:], body: $0.body)
        },
        Wrong(what: "a Retry-After that was not recorded", world: "practice-studying", exchange: "attempt-conflict", path: "headers.Retry-After") {
            Fixture.Response(status: $0.status, headers: ["retry-after": "5"], body: $0.body)
        },
        Wrong(what: "an empty answer", world: "practice-studying", exchange: "attempt-saved", path: "body") {
            Fixture.Response(status: $0.status, headers: $0.headers, body: .null)
        },
    ]

    /// `wrong.change` applied to the recording the replay meets, so the engine under test "answers" wrongly.
    @Test(arguments: wrongAnswers) private func aWrongAnswerFailsTheReplay(wrong: Wrong) async throws {
        let transcript = try Transcript.load(wrong.world)
        let engine = transcript.answering(wrong.exchange, wrong.change)
        let differences = try await replay(transcript, against: engine)
        let first = try #require(differences.first, "\(wrong.what) was not caught")
        #expect(differences.allSatisfy { $0.name == wrong.exchange && $0.step == first.step })
        #expect(differences.map(\.path).contains(wrong.path), "\(differences)")
    }

    /// Nothing after the first wrong answer is sent: the state is no longer the recording's.
    @Test func theReplayStopsAtTheFirstWrongAnswer() async throws {
        let transcript = try Transcript.load("practice-studying")
        let engine = TranscriptTransport(transcript.answering("attempt-saved") { $0.with("points") { _ in .number(9) } })
        let differences = try await TranscriptReplay.run(transcript, over: engine, hooks: .init(write: { _ in }))
        #expect(differences.map(\.path) == ["body.points"])
        let index = try #require(transcript.exchanges.firstIndex { $0.name == "attempt-saved" })
        #expect(engine.answered == index + 1)
    }

    // MARK: Only the volatile are let through

    @Test func aTimeWithinTheToleranceMatches() async throws {
        let transcript = try Transcript.load("practice-studying")
        let engine = transcript.answering("attempt-saved") { $0.with("answeredAt") { .string(Self.shifted($0, by: TranscriptReplay.timeTolerance - 0.005)) } }
        #expect(try await replay(transcript, against: engine).isEmpty)
    }

    /// An engine that hands one step's time to another (an exam's start as its finish, an earlier
    /// answer's time as a later one's) fails, however short the run.
    @Test func aTimeFromAnotherStepOfTheRunFails() async throws {
        let transcript = try Transcript.load("practice-studying")
        let exchanges = transcript.exchanges
        let saved = try #require(exchanges.firstIndex { $0.name == "attempt-saved" })
        let earlier = try #require(exchanges[..<saved].last { exchanges[saved].at.timeIntervalSince($0.at) > 0.1 })
        #expect(transcript.span < 2)
        let engine = transcript.answering("attempt-saved") { $0.with("answeredAt") { _ in .string(QBankJSON.formatDate(earlier.at)) } }
        let differences = try await replay(transcript, against: engine)
        #expect(differences.map(\.path) == ["body.answeredAt"])
    }

    @Test func aTimeInPostgresTextMatchesItsRecordedOneAndNoOtherTime() async throws {
        let recorded = Fixture.Response(status: 200, headers: [:], body: .object(["createdAt": .string("2026-11-13 21:55:59.443-05")]))
        var comparison = TranscriptReplay.Comparison(bound: .init(), tolerance: TranscriptReplay.timeTolerance)
        let same = try #require(HTTPURLResponse(url: TestClient.baseURL, statusCode: 200, httpVersion: nil, headerFields: [:]))
        comparison.compare(recorded, with: Data(#"{"createdAt":"2026-11-14T02:55:59.443Z"}"#.utf8), same)
        #expect(comparison.found.isEmpty)
        comparison.compare(recorded, with: Data(#"{"createdAt":"2026-11-14T03:55:59.443Z"}"#.utf8), same)
        #expect(comparison.found.map(\.path) == ["body.createdAt"])
    }

    /// The engine's own `confirm` token stands for the recorded one, and is what the replay then sends.
    @Test func anEnginesOwnConfirmTokenStandsForTheRecordedOne() async throws {
        let transcript = try Transcript.load("deletion-contents")
        let recorded = try #require(transcript.exchanges.first { $0.name == "practice-set-delete-preview" }?.response.body["confirm"]?.stringValue)
        let engine = transcript.renamingStrings { $0 == recorded ? "an-engine-token" : $0 }
        #expect(engine.exchanges.contains { $0.request.query["confirm"] == "an-engine-token" })
        #expect(try await replay(transcript, against: engine).isEmpty)
    }

    /// A recorded token or id meets one of the engine's, and the engine's one recorded one.
    @Test func boundValuesStandForEachOtherOneToOne() {
        var tokens = TranscriptReplay.Binding()
        let first = tokens.stand("engine-1", for: "recorded-1")
        let again = tokens.stand("engine-1", for: "recorded-1")
        let otherEngineToken = tokens.stand("engine-2", for: "recorded-1")
        let otherRecordedToken = tokens.stand("engine-1", for: "recorded-2")
        #expect(first && again)
        #expect(!otherEngineToken)
        #expect(!otherRecordedToken)
        #expect(tokens.sent("recorded-1") == "engine-1")
        #expect(tokens.sent("recorded-2") == "recorded-2")
    }

    /// Each way an engine's id can break the binding, at a step of `practice-studying`: 3 creates
    /// the course, the first id met in an answer after the semester's, and 11 saves an answer, whose
    /// ids are all met before.
    private struct Broken: CustomTestStringConvertible {
        let what: String
        let step: Int
        let path: String
        let change: @Sendable (Fixture.Response) -> Fixture.Response

        var testDescription: String { what }
    }

    private static let brokenIds: [Broken] = [
        Broken(what: "a bound id answered as another", step: 11, path: "body.questionId") {
            $0.with("questionId") { _ in .string("00000000-0000-4000-8010-0000000000ff") }
        },
        Broken(what: "a bound id answered as one that stands for another", step: 11, path: "body.questionId") { response in
            response.with("questionId") { _ in response.body["courseId"] }
        },
        Broken(what: "the client's own id answered as another", step: 11, path: "body.clientAttemptId") {
            $0.with("clientAttemptId") { _ in .string("00000000-0000-4000-8010-0000000000ff") }
        },
        Broken(what: "a new id answered as one that stands for another", step: 3, path: "body.id") {
            $0.with("id") { _ in .string("5e000000-0000-4000-8000-000000000201") }
        },
        Broken(what: "a new id answered as text that is no id", step: 3, path: "body.id") {
            $0.with("id") { _ in .string("course-1") }
        },
    ]

    @Test(arguments: brokenIds) private func anIdThatBreaksTheBindingFails(broken: Broken) async throws {
        let transcript = try Transcript.load("practice-studying")
        guard case .request(let exchange) = transcript.steps[broken.step] else { throw TestStepIsNotARequest() }
        #expect(exchange.response.body[String(broken.path.dropFirst("body.".count))]?.stringValue.map(TranscriptReplay.isID) == true)
        let differences = try await replay(transcript, against: transcript.answering(step: broken.step, broken.change))
        #expect(differences.map(\.path) == [broken.path], "\(differences)")
        #expect(differences.first?.step == broken.step)
    }

    private struct TestStepIsNotARequest: Error {}

    /// An id the client chooses is sent as recorded, so an engine that already answered it for an
    /// id of its own cannot be sent it, and the replay says so before sending.
    @Test func aClientsOwnIdTheEngineAlreadyMadeFails() async throws {
        let transcript = try Transcript.load("practice-studying")
        let first = try #require(transcript.exchanges.first { $0.name == "attempt-saved" }?.request.body?["clientAttemptId"]?.stringValue)
        let semester = "5e000000-0000-4000-8000-000000000201"
        let engine = transcript.renamingStrings { $0.replacing(semester, with: first) }
        let differences = try await replay(transcript, against: engine)
        #expect(differences.map(\.path) == ["request"], "\(differences)")
        #expect(differences.first?.actual == "the engine's id for \(semester)")
    }

    // MARK: The hooks

    /// The engine's clock is set to the time each request was recorded at, before the request, and
    /// a write is made where it fell in the recording.
    @Test func theReplaySetsTheClockAndMakesTheWritesInPlace() async throws {
        let transcript = try Transcript.load("practice-studying")
        let events = Mutex<[String]>([])
        let hooks = TranscriptReplay.Hooks(
            clock: { time in events.withLock { $0.append("clock \(QBankJSON.formatDate(time))") } },
            write: { write in events.withLock { $0.append("write \(write.table) \(write.id)") } })
        let recording = RecordingOfSends(TranscriptTransport(transcript)) { request in
            events.withLock { $0.append("send \(request.httpMethod ?? "") \(request.url?.path ?? "")") }
        }
        #expect(try await TranscriptReplay.run(transcript, over: recording, hooks: hooks).isEmpty)
        var expected: [String] = []
        for step in transcript.steps {
            switch step {
            case .request(let exchange): expected += ["clock \(QBankJSON.formatDate(exchange.at))", "send \(exchange.request.method) \(exchange.request.path)"]
            case .write(let write): expected += ["clock \(QBankJSON.formatDate(write.at))", "write \(write.table) \(write.id)"]
            }
        }
        #expect(events.withLock { $0 } == expected)
        #expect(events.withLock { $0 }.contains { $0.hasPrefix("write study_session ") })
    }

    /// The engine does not serve a password sign-in or an export: those steps are not sent and their
    /// answers not compared, but the clock still meets their times, in the recorded order.
    @Test func aStepTheEngineDoesNotServeIsSkippedAndKeepsItsPlaceOnTheClock() async throws {
        let transcript = try Transcript.load("practice-studying")
        let serves: @Sendable (Fixture.Request) -> Bool = { !["/api/sign-in/password", "/api/me/export"].contains($0.path) }
        let skipped = transcript.exchanges.filter { !serves($0.request) }
        #expect(skipped.count == 2)
        let events = Mutex<[String]>([])
        let hooks = TranscriptReplay.Hooks(
            clock: { time in events.withLock { $0.append("clock \(QBankJSON.formatDate(time))") } }, write: { _ in }, serves: serves)
        let engine = TranscriptTransport(transcript, serving: serves)
        let recording = RecordingOfSends(engine) { request in events.withLock { $0.append("send \(request.url?.path ?? "")") } }
        #expect(try await TranscriptReplay.run(transcript, over: recording, hooks: hooks).isEmpty)
        #expect(engine.answered == transcript.exchanges.count - skipped.count)
        var expected: [String] = []
        for step in transcript.steps {
            expected.append("clock \(QBankJSON.formatDate(step.at))")
            if case .request(let exchange) = step, serves(exchange.request) { expected.append("send \(exchange.request.path)") }
        }
        #expect(events.withLock { $0 } == expected)
    }

    @Test func aStepTheEngineDoesNotServeFailsWhenTheReplayIsNotTold() async throws {
        let transcript = try Transcript.load("practice-studying")
        let engine = TranscriptTransport(transcript) { $0.path != "/api/sign-in/password" }
        await #expect(throws: TranscriptTransport.Mismatch.self) {
            try await TranscriptReplay.run(transcript, over: engine, hooks: .init(write: { _ in }))
        }
    }

    @Test func aTranscriptWithAWriteCannotBeReplayedWithNoWayToMakeIt() async throws {
        let transcript = try Transcript.load("practice-studying")
        await #expect(throws: TranscriptReplay.Failure.self) {
            try await TranscriptReplay.run(transcript, over: TranscriptTransport(transcript), hooks: .init())
        }
    }

    @Test func aWriteNamesAStoredTimeInTheFormTheAPISends() throws {
        for transcript in try Transcript.all() {
            for case .write(let write) in transcript.steps {
                #expect(write.value.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil, "\(write)")
                #expect(write.id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil, "\(write)")
            }
        }
    }

    // MARK: What a replay sends

    @Test func theReplaySendsTheRequestAsTheAppDoes() throws {
        let transcript = try Transcript.load("deletion-contents")
        let exchange = try #require(transcript.exchanges.first { $0.name == "practice-set-delete" })
        let request = try TranscriptReplay.urlRequest(for: exchange.request, baseURL: TestClient.baseURL)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == exchange.request.path)
        #expect(request.url?.query?.hasPrefix("confirm=") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpBody == nil)
        let post = try #require(transcript.exchanges.first { $0.request.method == "POST" && $0.request.body != nil })
        let sent = try TranscriptReplay.urlRequest(for: post.request, baseURL: TestClient.baseURL)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try sent.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) } == post.request.body)
    }

    // MARK: The test doubles

    @Test func theRecordingRefusesARequestThatIsNotTheNextRecordedOne() async throws {
        let transcript = try Transcript.load("practice-studying")
        let recording = TranscriptTransport(transcript)
        var request = URLRequest(url: TestClient.baseURL.appending(path: "/api/semesters"))
        request.httpMethod = "GET"
        await #expect(throws: TranscriptTransport.Mismatch.self) { _ = try await recording.send(request) }
    }
}

// MARK: Helpers

/// Passes every request to `transport`, telling `seen` first.
private struct RecordingOfSends<Inner: HTTPTransport>: HTTPTransport {
    let inner: Inner
    let seen: @Sendable (URLRequest) -> Void

    init(_ inner: Inner, seen: @escaping @Sendable (URLRequest) -> Void) {
        self.inner = inner
        self.seen = seen
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen(request)
        return try await inner.send(request)
    }
}

extension Transcript {
    /// The transcript with the answer of the request at `step` changed.
    fileprivate func answering(step index: Int, _ change: (Fixture.Response) -> Fixture.Response) -> Transcript {
        var copy = self
        if case .request(let exchange) = steps[index] {
            copy.steps[index] = .request(Exchange(name: exchange.name, at: exchange.at, request: exchange.request, response: change(exchange.response)))
        }
        return copy
    }

    /// The transcript with the answer of the exchange `name` changed.
    fileprivate func answering(_ name: String, _ change: (Fixture.Response) -> Fixture.Response) -> Transcript {
        var copy = self
        copy.steps = steps.map { step in
            guard case .request(let exchange) = step, exchange.name == name else { return step }
            return .request(Exchange(name: name, at: exchange.at, request: exchange.request, response: change(exchange.response)))
        }
        return copy
    }

    /// How long the recording took, from its first step to its last.
    fileprivate var span: TimeInterval {
        guard let first = steps.first, let last = steps.last else { return 0 }
        return last.at.timeIntervalSince(first.at)
    }

    /// The transcript as an engine with its own ids would answer it: every id the server made (first
    /// met in an answer) is another, everywhere it appears, and the client's own (first met in a
    /// request) are as recorded.
    fileprivate func withEngineIds() throws -> Transcript {
        let pattern = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
        var engines: [String: String] = [:]
        var seen: Set<String> = []
        func meet(_ text: String, server: Bool) {
            for match in text.matches(of: pattern) where seen.insert(String(match.output)).inserted && server {
                engines[String(match.output)] = String(format: "ee000000-0000-4000-8eee-%012d", engines.count + 1)
            }
        }
        for case .request(let exchange) in steps {
            let request = exchange.request
            meet([request.path, request.query.description, request.body?.strings.joined(separator: " ") ?? ""].joined(separator: " "), server: false)
            meet(exchange.response.body.strings.joined(separator: " "), server: true)
        }
        #expect(!seen.contains { $0.hasPrefix("ee000000-") }, "the engine's ids must be new")
        let renamed = renamingStrings { $0.replacing(pattern) { engines[String($0.output)] ?? String($0.output) } }
        var copy = renamed
        copy.steps = renamed.steps.map { step in
            guard case .write(let write) = step else { return step }
            return .write(Transcript.Write(at: write.at, table: write.table, id: engines[write.id] ?? write.id, column: write.column, value: write.value))
        }
        return copy
    }

    /// The transcript with every string in every request and answer changed: an engine that wrote
    /// something else everywhere, so its answers and what it is later sent agree.
    fileprivate func renamingStrings(_ change: (String) -> String) -> Transcript {
        func deep(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text): .string(change(text))
            case .array(let items): .array(items.map(deep))
            case .object(let fields): .object(fields.mapValues(deep))
            default: value
            }
        }
        var copy = self
        copy.steps = steps.map { step in
            guard case .request(let exchange) = step else { return step }
            let request = Fixture.Request(
                method: exchange.request.method, path: change(exchange.request.path), query: exchange.request.query.mapValues(change), authorization: exchange.request.authorization,
                body: exchange.request.body.map(deep))
            return .request(Exchange(name: exchange.name, at: exchange.at, request: request, response: Fixture.Response(status: exchange.response.status, headers: exchange.response.headers, body: deep(exchange.response.body))))
        }
        return copy
    }
}

extension Fixture.Response {
    /// The answer with the key `key` of its body object changed (or removed, when `change` gives nil).
    fileprivate func with(_ key: String, _ change: (JSONValue?) -> JSONValue?) -> Fixture.Response {
        Fixture.Response(status: status, headers: headers, body: body.with(key, change))
    }
}

extension JSONValue {
    fileprivate func with(_ key: String, _ change: (JSONValue?) -> JSONValue?) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = change(fields[key])
        return .object(fields)
    }

    fileprivate var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Every string in the value, keys included.
    fileprivate var strings: [String] {
        switch self {
        case .string(let text): [text]
        case .array(let items): items.flatMap(\.strings)
        case .object(let fields): fields.flatMap { [$0.key] + $0.value.strings }
        default: []
        }
    }
}

extension TranscriptReplayTests {
    /// A recorded time moved by `seconds`, in the form the API sends.
    fileprivate static func shifted(_ time: JSONValue?, by seconds: TimeInterval) -> String {
        let date = time?.stringValue.flatMap(QBankJSON.parseDate) ?? Date(timeIntervalSince1970: 0)
        return QBankJSON.formatDate(date.addingTimeInterval(seconds))
    }
}
