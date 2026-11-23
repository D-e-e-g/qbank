import Foundation
import Testing

@testable import QBankKit

/// One world of the real server, recorded as everything that happened to it in order: each request
/// the scenario sent with the answer that came back, and each direct write that let time pass.
/// `test/record-contract.sh` writes one file per world to `Fixtures/transcripts/`. A fixture in
/// `Fixtures/contract/` is the named exchange of a transcript, and a transcript also holds the
/// setup calls between them, so replaying its requests in order meets the state the recording had.
///
/// Ids in a transcript are rewritten as in the fixtures: named by the scenario, or numbered in the
/// order the server first sent them. Session tokens are placeholders.
struct Transcript: Decodable {
    /// A request the recording sent and the answer it got.
    struct Exchange {
        /// The fixture this exchange is, or nil for a setup call no fixture keeps.
        let name: String?
        /// When the server took the request. A replay hands this to the engine's clock first.
        let at: Date
        let request: Fixture.Request
        let response: Fixture.Response
    }

    /// A write the scenario made straight to the server's database to let time pass: the row's
    /// time column took this value. A server has no route for it, so a replay makes it by hand.
    struct Write: Equatable {
        let at: Date
        /// The table, as the server and the phone's store both name it (`study_session`).
        let table: String
        let id: String
        /// The column, in the same snake case (`started_at`).
        let column: String
        /// The time the column holds afterwards, in the form the API sends.
        let value: String
    }

    enum Step {
        case request(Exchange)
        case write(Write)

        /// When the step happened.
        var at: Date {
            switch self {
            case .request(let exchange): exchange.at
            case .write(let write): write.at
            }
        }
    }

    let recordedFrom: String
    let world: String
    var steps: [Step]

    var exchanges: [Exchange] {
        steps.compactMap { if case .request(let exchange) = $0 { exchange } else { nil } }
    }

    private enum CodingKeys: String, CodingKey {
        case recordedFrom, world, steps
    }

    init(recordedFrom: String, world: String, steps: [Step]) {
        self.recordedFrom = recordedFrom
        self.world = world
        self.steps = steps
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordedFrom = try container.decode(String.self, forKey: .recordedFrom)
        world = try container.decode(String.self, forKey: .world)
        steps = try container.decode([StepFile].self, forKey: .steps).map(\.step)
    }

    /// The transcript of the world `name`.
    static func load(_ name: String) throws -> Transcript {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/transcripts"))
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    /// The transcript of the world `name` with the answers the server has since changed taken from `Fixtures/import-drift.json`: the
    /// question-file rules changed after the pinned commit, so a recorded import check no longer says what the server says. The
    /// recorded request and status stay, and every answer not listed is the recording's own. A re-record at a newer commit drops the file.
    static func loadWithImportDrift(_ name: String) throws -> Transcript {
        var transcript = try load(name)
        let url = try #require(Bundle.module.url(forResource: "import-drift", withExtension: "json", subdirectory: "Fixtures"))
        let file = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        for drift in file["steps"]?.arrayValue ?? [] where drift["transcript"]?.stringValue == name {
            guard let index = drift["step"].flatMap({ if case .number(let n) = $0 { Int(n) } else { nil } }), let body = drift["body"],
                case .request(let exchange) = transcript.steps[index]
            else { continue }
            let response = Fixture.Response(status: exchange.response.status, headers: exchange.response.headers, body: body)
            transcript.steps[index] = .request(Exchange(name: exchange.name, at: exchange.at, request: exchange.request, response: response))
        }
        return transcript
    }

    /// The name of every recorded world, in order.
    static func names() throws -> [String] {
        let directory = try #require(Bundle.module.url(forResource: "transcripts", withExtension: nil, subdirectory: "Fixtures"))
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    static func all() throws -> [Transcript] {
        try names().map(load)
    }

    /// The step's file form, which says what it is by its `step` key.
    private struct StepFile: Decodable {
        let step: Step

        private enum CodingKeys: String, CodingKey {
            case step, name, at, request, response, table, id, column, value
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let at = try Self.time(try container.decode(String.self, forKey: .at))
            switch try container.decode(String.self, forKey: .step) {
            case "request":
                step = .request(
                    Exchange(
                        name: try container.decodeIfPresent(String.self, forKey: .name),
                        at: at,
                        request: try container.decode(Fixture.Request.self, forKey: .request),
                        response: try container.decode(Fixture.Response.self, forKey: .response)))
            case "write":
                step = .write(
                    Write(
                        at: at,
                        table: try container.decode(String.self, forKey: .table),
                        id: try container.decode(String.self, forKey: .id),
                        column: try container.decode(String.self, forKey: .column),
                        value: try container.decode(String.self, forKey: .value)))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .step, in: container, debugDescription: "Unknown step \(other)")
            }
        }

        private static func time(_ text: String) throws -> Date {
            guard let date = QBankJSON.parseDate(text) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a time: \(text)")) }
            return date
        }
    }
}
