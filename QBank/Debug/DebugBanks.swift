#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// Banks with invented sets in them, for the scenarios of a bank that moves between this iPhone and
/// QBank Cloud: each set goes in through the bank's own import, as a person's would, so the bank is
/// one the app could have made. Compiled only into Debug builds.
nonisolated enum DebugBanks {
    /// A set to import: its question file, into the topic of this name, made when the bank has none.
    struct Set {
        let topic: String
        let source: String
    }

    static let geography = "Geography"
    /// The name a returning subscriber gave `geography` on this iPhone while Cloud was off.
    static let renamedGeography = "World geography"

    /// A set QBank Cloud holds that the bank on this iPhone does not.
    static let capitals = Set(
        topic: geography,
        source: questionFile(
            "Invented capitals",
            [("Which city is the capital of the invented land of Norvia?", ["Pellmar", "Ostrin", "Varda"]), ("Which river runs through Pellmar?", ["The Sile", "The Orne", "The Tave"]), ("Which sea lies east of Norvia?", ["The Glass Sea", "The Amber Sea", "The Quiet Sea"])]))

    /// A set the bank on this iPhone holds that QBank Cloud does not.
    static let rivers = Set(
        topic: geography,
        source: questionFile(
            "Invented rivers",
            [("Which invented river is the longest?", ["The Sile", "The Orne", "The Tave"]), ("Where does the Orne meet the sea?", ["At Ostrin", "At Varda", "At Pellmar"])]))

    /// Imports each of `sets` into `bank`, after the sample set `sample` when given, and waits until
    /// every one is in, before the launch goes on. The bank is in memory or in the scenario's own
    /// folder, so this takes a moment only.
    static func fill(_ bank: LocalBank, sample: String?, with sets: [Set]) {
        if let sample {
            do {
                try bank.fileSampleSet(sample, inTopic: SampleSet.topic)
            } catch {
                fatalError("The scenario's sample set could not be filed: \(error)")
            }
        }
        let failure = Mutex<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await importAll(sets, into: bank)
            } catch {
                failure.withLock { $0 = String(describing: error) }
            }
            done.signal()
        }
        done.wait()
        if let failure = failure.withLock({ $0 }) {
            fatalError("The scenario's bank could not be filled: \(failure)")
        }
    }

    /// The same, for a caller that can wait, such as a test, rather than block the launch.
    static func filled(_ bank: LocalBank, sample: String?, with sets: [Set]) async throws {
        if let sample { try bank.fileSampleSet(sample, inTopic: SampleSet.topic) }
        try await importAll(sets, into: bank)
    }

    /// Renames the topic `topic` of `bank` to `name`, as a person does in the app, and waits until it is.
    static func rename(topic: String, to name: String, in bank: LocalBank) {
        let failure = Mutex<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let catalog = try await answer(bank, "GET", "/api/semesters", nil)
                guard let id = catalog["topics"]?.arrayValue?.first(where: { $0["title"]?.stringValue == topic })?["id"]?.stringValue else {
                    throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "no topic \(topic)"])
                }
                _ = try await answer(bank, "PATCH", "/api/courses/\(id)", ["title": .string(name)])
            } catch {
                failure.withLock { $0 = String(describing: error) }
            }
            done.signal()
        }
        done.wait()
        if let failure = failure.withLock({ $0 }) {
            fatalError("The scenario's topic could not be renamed: \(failure)")
        }
    }

    private static func importAll(_ sets: [Set], into bank: LocalBank) async throws {
        var topics: [String: String] = [:]
        for set in sets {
            let topic: String
            if let made = topics[set.topic] {
                topic = made
            } else {
                topic = try await send(bank, "/api/topics", ["title": .string(set.topic)])
                topics[set.topic] = topic
            }
            _ = try await send(bank, "/api/imports", ["source": .string(set.source), "courseId": .string(topic), "decision": .string("import")], id: "setId")
        }
    }

    /// Posts `body` to `path` on `bank` and returns the id the answer names.
    private static func send(_ bank: LocalBank, _ path: String, _ body: [String: JSONValue], id: String = "id") async throws -> String {
        guard let made = try await answer(bank, "POST", path, body, expecting: 201)[id]?.stringValue else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "\(path) named no \(id)"])
        }
        return made
    }

    /// Sends `method` `path` with `body` to `bank` and returns its answer, which must have `status`.
    private static func answer(_ bank: LocalBank, _ method: String, _ path: String, _ body: [String: JSONValue]?, expecting status: Int = 200) async throws -> JSONValue {
        guard let url = URL(string: "https://fake-qbank.invalid\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        }
        let (data, response) = try await bank.send(request)
        guard response.statusCode == status else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) answered \(response.statusCode)"])
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A question file of single-answer questions, the first choice right.
    private static func questionFile(_ title: String, _ questions: [(ask: String, choices: [String])]) -> String {
        let file = JSONValue.object([
            "title": .string(title),
            "questions": .array(
                questions.enumerated().map { index, question in
                    .object([
                        "id": .string("Q\(index + 1)"), "type": .string("single"), "ask": .string(question.ask),
                        "options": .array(question.choices.enumerated().map { choice, text in .object(choice == 0 ? ["t": .string(text), "ok": .bool(true)] : ["t": .string(text)]) }),
                    ])
                }),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(file)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
#endif
