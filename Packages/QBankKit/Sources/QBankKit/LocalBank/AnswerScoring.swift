import Foundation

/// Scoring one answer against a stored question, with the server's checks and the server's words
/// for each way an answer can be refused (`invalid_response`, 400).
enum AnswerScoring {
    /// The question's format and the mark the answer earns.
    struct Result {
        let type: QuestionType
        let score: Score
    }

    private static func invalid(_ message: String) -> BankRefusal { BankRefusal(status: 400, code: "invalid_response", message: message) }

    /// Scores `response` against a stored question of `typeName` whose body is the JSON text `body`.
    ///
    /// The order is the server's. A response that is not an object is "Send the answer."; a question
    /// the scorer cannot read is "That question can't be scored."; an answer in another format keeps
    /// the scorer's reason; and an answer of the right format that is not well formed (a choice of
    /// "0", a pick that is not a whole number) is "That answer does not match this question." before
    /// anything is saved.
    static func score(typeName: String, body: String, response: JSONValue?) throws -> Result {
        guard case .object(let fields)? = response else { throw invalid("Send the answer.") }
        guard let type = QuestionType(rawValue: typeName), let node = try? JSParser.parse(body), case .object = node,
            let parsed = try? QuestionBody(typeName: typeName, json: node.json)
        else { throw invalid("That question can't be scored.") }
        guard fields["type"]?.stringValue == type.rawValue else {
            throw invalid("Cannot score a \(type.rawValue) question with a \(jsText(fields["type"])) answer.")
        }
        guard isResponse(.object(fields)), let answer = try? response?.decode(AnswerResponse.self) else {
            throw invalid("That answer does not match this question.")
        }
        do {
            return Result(type: type, score: try Scoring.score(parsed, response: answer))
        } catch {
            throw invalid(error.message)
        }
    }

    /// Whether a value is an answer in the shape of its format: `type` names a format and its fields
    /// are there, with whole numbers for indexes. An index out of range is well formed and scores as wrong.
    static func isResponse(_ value: JSONValue) -> Bool {
        guard case .object(let answer) = value, let type = answer["type"]?.stringValue, QuestionType(rawValue: type) != nil else { return false }
        switch type {
        case "single", "priority": return isWhole(answer["choice"])
        case "sata", "highlight": return list(answer["picks"], isWhole)
        case "order": return list(answer["positions"], isWhole)
        case "match", "matrix": return list(answer["choices"]) { $0 == .null || $0?.stringValue != nil }
        case "matrixmulti": return list(answer["choices"]) { list($0) { $0?.stringValue != nil } }
        default: return list(answer["choices"]) { $0 == .null || isWhole($0) }
        }
    }

    private static func list(_ value: JSONValue?, _ isItem: (JSONValue?) -> Bool) -> Bool {
        guard case .array(let items)? = value else { return false }
        return items.allSatisfy { isItem($0) }
    }

    /// JavaScript's `Number.isInteger`, within what a stored index can hold.
    private static func isWhole(_ value: JSONValue?) -> Bool {
        guard case .number(let number)? = value else { return false }
        return number.isFinite && number == number.rounded() && abs(number) < 9e15
    }

    /// How JavaScript writes a value into a template string, for the one message that names the answer's format.
    private static func jsText(_ value: JSONValue?) -> String {
        switch value {
        case nil: "undefined"
        case .null: "null"
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): JS.numberString(number)
        case .string(let text): text
        case .array(let items): items.map { $0 == .null ? "" : jsText($0) }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }
}
