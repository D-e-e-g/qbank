import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@testable import QBankKit

/// Replays a transcript's requests, in order, against any `HTTPTransport` and compares each answer
/// with the recorded one. It is how an engine that answers the server's contract is proven to
/// answer as the server does: the engine passes when every transcript it serves replays with no
/// difference.
///
/// An answer must match the recorded one in its status, its `Retry-After` header and its whole body:
/// every key present on both sides, every list the same length, every value equal. Three kinds of
/// value are not compared as text, and nothing else is ignored:
///
/// - **A time.** A string in a time form the API sends (`2026-11-22T14:37:05.123Z`, or Postgres's
///   `2026-11-22 14:37:05.123-05`) matches a time within `tolerance` of the recorded one, and a
///   string that is not a time never matches one. The recording's times are those of the day it was
///   made, so the replay first hands the engine's clock the time each request was recorded at
///   (`Hooks.clock`). What remains is the time the server took to stamp it, which the recorder
///   keeps within `timeTolerance` (`test/record-contract/world.ts`), so a time from another step
///   fails.
/// - **An id.** A recording's ids are rewritten (named by the scenario, or numbered in the order the
///   server first sent them), so no engine can make the recorded ones. An id is bound one to one,
///   in the order the replay meets it. An id first met in a recorded answer stands for the id the
///   engine answered in its place, from then on, and the replay sends the engine's id wherever the
///   recording sent the recorded one: in a path, a query, a body and a write. An id first met in a
///   recorded request is the client's own (an answer's `clientAttemptId`, or an id sent to be not
///   found): it is sent as recorded and stands only for itself.
/// - **A `confirm` token.** The server hashes it from the real ids a delete preview names, which a
///   recording rewrites, so no engine can make the recorded text. It is bound one to one the same
///   way, from the first answer that carries it.
///
/// A direct write in the transcript (`Transcript.Write`) has no route, so the replay hands it to
/// `Hooks.write`; a transcript with a write and no handler cannot be replayed. A request the engine
/// does not serve by design (`Hooks.serves`) is not sent and its answer not compared, but the clock
/// still meets its time, so the clock sees every step in the recorded order.
enum TranscriptReplay {
    /// How the replay reaches what a request cannot: the engine's clock and its store, and which
    /// requests the engine serves.
    struct Hooks: Sendable {
        /// Called with the time a step was recorded at, before the step, served or not.
        var clock: @Sendable (Date) async throws -> Void = { _ in }
        /// Called for each direct write, in place, with the engine's ids. Nil when the engine has no way to make one.
        var write: (@Sendable (Transcript.Write) async throws -> Void)?
        /// Whether the engine serves a recorded request. One it does not is skipped.
        var serves: @Sendable (Fixture.Request) -> Bool = { _ in true }
        /// Whether the answer to a request lists its `questions` in an order the server draws at random, so a list is
        /// compared as the same questions in any order, each with its own `position` left out.
        var shuffles: @Sendable (Fixture.Request) -> Bool = { _ in false }

        init(
            clock: @escaping @Sendable (Date) async throws -> Void = { _ in }, write: (@Sendable (Transcript.Write) async throws -> Void)? = nil,
            serves: @escaping @Sendable (Fixture.Request) -> Bool = { _ in true }, shuffles: @escaping @Sendable (Fixture.Request) -> Bool = { _ in false }
        ) {
            self.clock = clock
            self.write = write
            self.serves = serves
            self.shuffles = shuffles
        }
    }

    /// One place an answer is not the recorded one.
    struct Difference: Equatable, CustomStringConvertible {
        /// The step of the transcript, counting its writes.
        let step: Int
        /// The fixture the step is, when it is one.
        let name: String?
        /// Where in the answer: `status`, `headers.Retry-After` or `body.folders[2].name`, or `request` for an id the request cannot send.
        let path: String
        let expected: String
        let actual: String

        var description: String {
            "step \(step)\(name.map { " (\($0))" } ?? ""), \(path): recorded \(expected), answered \(actual)"
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case cannotWrite(Transcript.Write)

        var description: String {
            switch self {
            case .cannotWrite(let write): "The transcript writes \(write.table).\(write.column) of \(write.id), and the replay has no handler for it"
            }
        }
    }

    /// How far apart two times may be and still match. The engine's clock is set to the time each
    /// request was recorded at, so what remains is how long the server took to stamp a time while
    /// answering. The recorder holds the server's clock while it answers and fails a recording in
    /// which that is still longer than this (`TIME_TOLERANCE_MS` in `test/record-contract/world.ts`,
    /// which must stay equal to it).
    static let timeTolerance: TimeInterval = 0.025

    /// Replays the transcript against `transport`. Returns no difference when every answer matched,
    /// and otherwise the differences of the first step that did not match: after one the state is
    /// no longer the recording's, so later answers say nothing.
    static func run(
        _ transcript: Transcript, over transport: some HTTPTransport, baseURL: URL = TestClient.baseURL, tolerance: TimeInterval = timeTolerance, hooks: Hooks = Hooks()
    ) async throws -> [Difference] {
        var bound = Bound()
        for (index, step) in transcript.steps.enumerated() {
            switch step {
            case .write(let write):
                guard let apply = hooks.write else { throw Failure.cannotWrite(write) }
                try await hooks.clock(write.at)
                try await apply(bound.sent(write))
            case .request(let exchange):
                try await hooks.clock(exchange.at)
                if let clash = bound.meet(exchange.request) {
                    return [Difference(step: index, name: exchange.name, path: "request", expected: "\(clash.id), the client's own id", actual: "the engine's id for \(clash.standsFor)")]
                }
                guard hooks.serves(exchange.request) else { continue }
                let request = try urlRequest(for: exchange.request, baseURL: baseURL, bound: bound)
                let (data, response) = try await transport.send(request)
                var comparison = Comparison(bound: bound, tolerance: tolerance, shuffled: hooks.shuffles(exchange.request))
                comparison.compare(exchange.response, with: data, response)
                bound = comparison.bound
                if !comparison.found.isEmpty {
                    return comparison.found.map { Difference(step: index, name: exchange.name, path: $0.path, expected: $0.expected, actual: $0.actual) }
                }
            }
        }
        return []
    }

    /// The request as the app sends it (a delete sends its `confirm` in the query, other routes in the body), with the engine's ids and `confirm` tokens in place of the recorded ones.
    static func urlRequest(for recorded: Fixture.Request, baseURL: URL, bound: Bound = Bound()) throws -> URLRequest {
        let sent = bound.sent(recorded)
        var components = try #require(URLComponents(url: baseURL, resolvingAgainstBaseURL: false))
        components.path = sent.path
        if !sent.query.isEmpty {
            components.queryItems = sent.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: try #require(components.url))
        request.httpMethod = sent.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = sent.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let body = sent.body, !body.isNull {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// The time in a string the API sends as one, or nil for any other string.
    static func time(_ text: String) -> Date? {
        guard text.prefixMatch(of: /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/) != nil else { return nil }
        return QBankJSON.parseDate(text)
    }

    /// An id as the API writes one: a lowercase UUID.
    static var id: Regex<Substring> { /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ }

    /// Whether the whole string is an id.
    static func isID(_ text: String) -> Bool {
        text.wholeMatch(of: id) != nil
    }

    /// Recorded values bound one to one to the engine's, in the order the replay meets them.
    struct Binding {
        /// The engine's value for each recorded one.
        private(set) var engines: [String: String] = [:]
        /// The recorded value each of the engine's stands for.
        private(set) var recordeds: [String: String] = [:]

        /// Whether the engine's `actual` may stand for the recorded `expected`, binding the two if
        /// neither is bound yet. Once bound, each stands only for the other.
        mutating func stand(_ actual: String, for expected: String) -> Bool {
            if let known = engines[expected] { return known == actual }
            guard recordeds[actual] == nil else { return false }
            engines[expected] = actual
            recordeds[actual] = expected
            return true
        }

        /// A recorded value, replaced by the engine's when one stands for it.
        func sent(_ text: String) -> String {
            engines[text] ?? text
        }
    }

    /// The ids and `confirm` tokens met so far.
    struct Bound {
        var ids = Binding()
        var tokens = Binding()

        /// Binds each id the recorded request names that no earlier step met: the client's own, which
        /// stands for itself. Returns the first such id the engine already answered for another
        /// recorded id, which the request can then not send.
        mutating func meet(_ request: Fixture.Request) -> (id: String, standsFor: String)? {
            var named = request.path.matches(of: TranscriptReplay.id).map { String($0.output) }
            for (key, value) in request.query.sorted(by: { $0.key < $1.key }) { named += Self.named(in: .string(key)) + Self.named(in: .string(value)) }
            named += request.body.map(Self.named) ?? []
            for id in named where ids.engines[id] == nil {
                if !ids.stand(id, for: id) { return (id, ids.recordeds[id] ?? "?") }
            }
            return nil
        }

        /// The recorded request with the engine's ids and tokens in place of the recorded ones.
        func sent(_ request: Fixture.Request) -> Fixture.Request {
            Fixture.Request(
                method: request.method, path: translated(request.path),
                query: Dictionary(uniqueKeysWithValues: request.query.map { (translated($0.key), tokens.sent(translated($0.value))) }),
                authorization: request.authorization, body: request.body.map(sent))
        }

        /// The recorded write, on the engine's row.
        func sent(_ write: Transcript.Write) -> Transcript.Write {
            Transcript.Write(at: write.at, table: write.table, id: translated(write.id), column: write.column, value: write.value)
        }

        /// A request body with each recorded id and token replaced by the engine's.
        func sent(_ body: JSONValue) -> JSONValue {
            switch body {
            case .string(let text): .string(tokens.sent(translated(text)))
            case .array(let items): .array(items.map(sent))
            case .object(let fields): .object(Dictionary(uniqueKeysWithValues: fields.map { (translated($0.key), sent($0.value)) }))
            default: body
            }
        }

        /// Text with every recorded id in it replaced by the engine's.
        private func translated(_ text: String) -> String {
            text.replacing(TranscriptReplay.id) { ids.sent(String($0.output)) }
        }

        /// Every id in a value, keys included, in order.
        private static func named(in value: JSONValue) -> [String] {
            switch value {
            case .string(let text): text.matches(of: TranscriptReplay.id).map { String($0.output) }
            case .array(let items): items.flatMap(named)
            case .object(let fields): fields.sorted { $0.key < $1.key }.flatMap { named(in: .string($0.key)) + named(in: $0.value) }
            default: []
            }
        }
    }

    /// The comparison of one answer with its recording.
    struct Comparison {
        var bound: Bound
        let tolerance: TimeInterval
        let shuffled: Bool
        private(set) var found: [(path: String, expected: String, actual: String)] = []

        init(bound: Bound, tolerance: TimeInterval, shuffled: Bool = false) {
            self.bound = bound
            self.tolerance = tolerance
            self.shuffled = shuffled
        }

        /// A list of questions the server drew in a random order, read in the order of the questions' own names.
        /// An exam's result lists its marks in the same order, so they follow the questions.
        private static func inNameOrder(_ body: JSONValue) -> JSONValue {
            guard case .object(var fields) = body, case .array(let questions)? = fields["questions"] else { return body }
            // A question's name repeats across sets, so its stem tells two of one name apart.
            let key = { (index: Int) in (questions[index]["publicId"]?.stringValue ?? "") + "\u{0}" + (questions[index]["stem"]?.stringValue ?? "") }
            let order = questions.indices.sorted { key($0) < key($1) }
            fields["questions"] = .array(
                order.map { index in
                    guard case .object(var one) = questions[index] else { return questions[index] }
                    one["position"] = .null
                    return .object(one)
                })
            if case .object(var result)? = fields["result"], case .array(let items)? = result["items"], items.count == questions.count {
                result["items"] = .array(order.map { items[$0] })
                fields["result"] = .object(result)
            }
            return .object(fields)
        }

        mutating func compare(_ expected: Fixture.Response, with data: Data, _ response: HTTPURLResponse) {
            note("status", String(expected.status), String(response.statusCode))
            // The recorder keeps the one header a client reads, and a header it did not keep must not appear.
            for (name, value) in expected.headers.sorted(by: { $0.key < $1.key }) {
                note("headers.\(name)", value, response.value(forHTTPHeaderField: name) ?? "none")
            }
            if expected.headers.keys.first(where: { $0.lowercased() == "retry-after" }) == nil, let extra = response.value(forHTTPHeaderField: "Retry-After") {
                note("headers.Retry-After", "none", extra)
            }
            var body = JSONValue.null
            if !data.isEmpty {
                guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    note("body", Self.show(expected.body), "not JSON: \(String(decoding: data.prefix(80), as: UTF8.self))")
                    return
                }
                body = decoded
            }
            if shuffled {
                compare(Self.inNameOrder(expected.body), Self.inNameOrder(body), at: "body")
            } else {
                compare(expected.body, body, at: "body")
            }
        }

        mutating func compare(_ expected: JSONValue, _ actual: JSONValue, at path: String, key: String? = nil) {
            switch (expected, actual) {
            case (.object(let recorded), .object(let answered)):
                for name in Set(recorded.keys).union(answered.keys).sorted() {
                    switch (recorded[name], answered[name]) {
                    case (let one?, let other?): compare(one, other, at: "\(path).\(name)", key: name)
                    case (let one?, nil): note("\(path).\(name)", Self.show(one), "missing")
                    case (nil, let other?): note("\(path).\(name)", "absent", Self.show(other))
                    case (nil, nil): break
                    }
                }
            case (.array(let recorded), .array(let answered)):
                guard recorded.count == answered.count else {
                    note(path, "\(recorded.count) items", "\(answered.count) items")
                    return
                }
                for (index, pair) in zip(recorded, answered).enumerated() {
                    compare(pair.0, pair.1, at: "\(path)[\(index)]")
                }
            case (.string(let recorded), .string(let answered)):
                if key == "confirm" {
                    if !bound.tokens.stand(answered, for: recorded) { note(path, Self.owed(recorded, in: bound.tokens, "token"), answered) }
                } else if TranscriptReplay.isID(recorded) {
                    if !TranscriptReplay.isID(answered) || !bound.ids.stand(answered, for: recorded) { note(path, Self.owed(recorded, in: bound.ids, "id"), answered) }
                } else if recorded == answered {
                    return
                } else if let one = TranscriptReplay.time(recorded), let other = TranscriptReplay.time(answered) {
                    if abs(one.timeIntervalSince(other)) > tolerance { note(path, recorded, answered) }
                } else {
                    note(path, Self.show(expected), Self.show(actual))
                }
            default:
                if expected != actual { note(path, Self.show(expected), Self.show(actual)) }
            }
        }

        private mutating func note(_ path: String, _ expected: String, _ actual: String) {
            if expected != actual { found.append((path, expected, actual)) }
        }

        /// What the engine had to answer for a recorded id or token, for a message.
        private static func owed(_ recorded: String, in binding: Binding, _ what: String) -> String {
            if let known = binding.engines[recorded] { return known == recorded ? recorded : "\(known), the \(what) that stood for \(recorded)" }
            return "a new \(what) of the engine's for \(recorded)"
        }

        /// A value as short JSON text, for a message.
        static func show(_ value: JSONValue) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            return text.count > 120 ? "\(text.prefix(120))..." : text
        }
    }
}

/// A recording as the server: answers each request with the next recorded answer, after checking
/// that the request is the next recorded one. Replaying a transcript against it is the proof that
/// the replay sends what the recording sent and accepts what the recording answered. Given
/// `serving`, it holds only the requests that says it serves, as an engine that serves only those.
final class TranscriptTransport: HTTPTransport, @unchecked Sendable {
    struct Mismatch: Error, CustomStringConvertible {
        let step: Int
        let reason: String

        var description: String { "request \(step) is not the recorded one: \(reason)" }
    }

    private let exchanges: [Transcript.Exchange]
    private let next = Mutex(0)

    init(_ transcript: Transcript, serving: (Fixture.Request) -> Bool = { _ in true }) {
        exchanges = transcript.exchanges.filter { serving($0.request) }
    }

    /// How many requests it has answered.
    var answered: Int { next.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = next.withLock { count in
            defer { count += 1 }
            return count
        }
        guard step < exchanges.count else { throw Mismatch(step: step, reason: "the recording ends") }
        let recorded = exchanges[step]
        if let reason = Self.difference(request, from: recorded.request) { throw Mismatch(step: step, reason: reason) }
        let headers = recorded.response.headers.merging(["Content-Type": "application/json"]) { old, _ in old }
        let response = try #require(HTTPURLResponse(url: TestClient.baseURL, statusCode: recorded.response.status, httpVersion: "HTTP/1.1", headerFields: headers))
        return (recorded.response.body.isNull ? Data() : try JSONEncoder().encode(recorded.response.body), response)
    }

    /// What differs between a request and the recorded one, or nil when they are the same.
    static func difference(_ request: URLRequest, from recorded: Fixture.Request) -> String? {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "no URL" }
        if request.httpMethod != recorded.method { return "method \(request.httpMethod ?? "none"), recorded \(recorded.method)" }
        if components.path != recorded.path { return "path \(components.path), recorded \(recorded.path)" }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if query != recorded.query { return "query \(query), recorded \(recorded.query)" }
        if request.value(forHTTPHeaderField: "Authorization") != recorded.authorization { return "authorization" }
        let sent = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let expected = recorded.body.flatMap { $0.isNull ? nil : $0 }
        if sent != expected { return "body \(sent.map(TranscriptReplay.Comparison.show) ?? "none"), recorded \(expected.map(TranscriptReplay.Comparison.show) ?? "none")" }
        return nil
    }
}
