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
/// every key present on both sides, every list the same length, every value equal. Only two kinds
/// of value are volatile, and nothing else is ignored:
///
/// - **A time.** A string in a time form the API sends (`2026-11-22T14:37:05.123Z`, or Postgres's
///   `2026-11-22 14:37:05.123-05`) matches a time within `tolerance` of the recorded one, and a
///   string that is not a time never matches one. The recording's times are those of the day it was
///   made, so the replay first hands the engine's clock the time each request was recorded at
///   (`Hooks.clock`), and the engine's times then fall within a few milliseconds of the recorded
///   ones.
/// - **A `confirm` token.** The server hashes it from the real ids a delete preview names, which a
///   recording rewrites, so no engine can make the recorded text. A token matches when it is a
///   string, and the replay then sends the engine's own token wherever the recording sent the one it
///   stood for. A recorded token meets one token of the engine's, and the engine's token one
///   recorded token, from the first answer that carries it to the end.
///
/// Ids are not volatile: the engine's ids must be the recording's, which is why the engine takes an
/// id generator (docs/on-phone-bank.md, rule 5). A direct write in the transcript (`Transcript.Write`)
/// has no route, so the replay hands it to `Hooks.write`; a transcript with a write and no
/// handler cannot be replayed.
enum TranscriptReplay {
    /// How the replay reaches what a request cannot: the engine's clock and its store.
    struct Hooks: Sendable {
        /// Called with the time a step was recorded at, before the step.
        var clock: @Sendable (Date) async throws -> Void = { _ in }
        /// Called for each direct write, in place. Nil when the engine has no way to make one.
        var write: (@Sendable (Transcript.Write) async throws -> Void)?

        init(clock: @escaping @Sendable (Date) async throws -> Void = { _ in }, write: (@Sendable (Transcript.Write) async throws -> Void)? = nil) {
            self.clock = clock
            self.write = write
        }
    }

    /// One place an answer is not the recorded one.
    struct Difference: Equatable, CustomStringConvertible {
        /// The step of the transcript, counting its writes.
        let step: Int
        /// The fixture the step is, when it is one.
        let name: String?
        /// Where in the answer: `status`, `headers.Retry-After` or `body.folders[2].name`.
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

    /// How far apart two times may be and still match. The engine's clock is set to the recorded
    /// time, so what remains is the few milliseconds the server took.
    static let timeTolerance: TimeInterval = 5

    /// Replays the transcript against `transport`. Returns no difference when every answer matched,
    /// and otherwise the differences of the first step that did not match: after one the state is
    /// no longer the recording's, so later answers say nothing.
    static func run(
        _ transcript: Transcript, over transport: some HTTPTransport, baseURL: URL = TestClient.baseURL, tolerance: TimeInterval = timeTolerance, hooks: Hooks = Hooks()
    ) async throws -> [Difference] {
        var tokens = Tokens()
        for (index, step) in transcript.steps.enumerated() {
            switch step {
            case .write(let write):
                guard let apply = hooks.write else { throw Failure.cannotWrite(write) }
                try await hooks.clock(write.at)
                try await apply(write)
            case .request(let exchange):
                try await hooks.clock(exchange.at)
                let request = try urlRequest(for: exchange.request, baseURL: baseURL, tokens: tokens)
                let (data, response) = try await transport.send(request)
                var comparison = Comparison(tokens: tokens, tolerance: tolerance)
                comparison.compare(exchange.response, with: data, response)
                tokens = comparison.tokens
                if !comparison.found.isEmpty {
                    return comparison.found.map { Difference(step: index, name: exchange.name, path: $0.path, expected: $0.expected, actual: $0.actual) }
                }
            }
        }
        return []
    }

    /// The request as the app sends it (a delete sends its `confirm` in the query, other routes in the body), with the engine's `confirm` tokens in place of the recorded ones.
    static func urlRequest(for recorded: Fixture.Request, baseURL: URL, tokens: Tokens = Tokens()) throws -> URLRequest {
        var components = try #require(URLComponents(url: baseURL, resolvingAgainstBaseURL: false))
        components.path = recorded.path
        if !recorded.query.isEmpty {
            components.queryItems = recorded.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: tokens.sent($0.value)) }
        }
        var request = URLRequest(url: try #require(components.url))
        request.httpMethod = recorded.method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = recorded.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let body = recorded.body, !body.isNull {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(tokens.sent(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// The time in a string the API sends as one, or nil for any other string.
    static func time(_ text: String) -> Date? {
        guard text.prefixMatch(of: /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/) != nil else { return nil }
        return QBankJSON.parseDate(text)
    }

    /// The `confirm` tokens met so far: the one the recording had, and the one the engine made for it.
    struct Tokens {
        private(set) var engines: [String: String] = [:]
        private var used: Set<String> = []

        /// Whether the engine's `actual` may stand for the recorded `expected`, remembering it if so.
        mutating func stand(_ actual: String, for expected: String) -> Bool {
            if let known = engines[expected] { return known == actual }
            guard !used.contains(actual) else { return false }
            engines[expected] = actual
            used.insert(actual)
            return true
        }

        /// A string a request sends, replaced by the engine's token when it is a recorded one.
        func sent(_ text: String) -> String {
            engines[text] ?? text
        }

        /// A request body with each recorded token the engine has made another for, replaced by it.
        func sent(_ body: JSONValue) -> JSONValue {
            switch body {
            case .string(let text): .string(sent(text))
            case .array(let items): .array(items.map(sent))
            case .object(let fields): .object(fields.mapValues(sent))
            default: body
            }
        }
    }

    /// The comparison of one answer with its recording.
    struct Comparison {
        var tokens: Tokens
        let tolerance: TimeInterval
        private(set) var found: [(path: String, expected: String, actual: String)] = []

        init(tokens: Tokens, tolerance: TimeInterval) {
            self.tokens = tokens
            self.tolerance = tolerance
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
            compare(expected.body, body, at: "body")
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
                    if !tokens.stand(answered, for: recorded) { note(path, "the token that stood for \(recorded)", answered) }
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
/// the replay sends what the recording sent and accepts what the recording answered.
final class TranscriptTransport: HTTPTransport, @unchecked Sendable {
    struct Mismatch: Error, CustomStringConvertible {
        let step: Int
        let reason: String

        var description: String { "request \(step) is not the recorded one: \(reason)" }
    }

    private let exchanges: [Transcript.Exchange]
    private let next = Mutex(0)

    init(_ transcript: Transcript) {
        exchanges = transcript.exchanges
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
