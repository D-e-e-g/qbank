import Foundation

/// The nine question formats the runner supports.
public enum QuestionType: String, Codable, Sendable, CaseIterable {
    case single
    case priority
    case sata
    case highlight
    case order
    case match
    case matrix
    /// A matrix where one row can fit more than one column.
    case matrixmulti
    case cloze
}

/// `GET /api/practice-sets/{id}`, and the Review runner's questions, which share the shape.
public struct PracticeSet: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case practice
        /// An exam bank. The app never lists one for practice.
        case exam
    }

    /// The set id, or the course id for a Review run.
    public let id: String
    public let courseID: String
    public let title: String
    /// Its folder's name. Empty for a Review run.
    public let weekLabel: String
    /// Its folder. Nil for a Review run, and from a server older than folders.
    public let folderID: String?
    public let kind: Kind
    /// In the order she practices them.
    public let questions: [Question]
    /// How far she has got through the set this time.
    public var sitting: Sitting?
    /// Where she stands in the set. Nil for a Review run or samples, and from a server or a saved
    /// copy from before `run`: the runner then reads it from the set's row.
    public var run: SetRun?

    /// Questions to practice that are not a set on the server, such as the samples of a set being
    /// made. Nothing about them is in any folder.
    public init(id: String, courseID: String, title: String, questions: [Question]) {
        self.id = id
        self.courseID = courseID
        self.title = title
        weekLabel = ""
        folderID = nil
        kind = .practice
        self.questions = questions
    }

    enum CodingKeys: String, CodingKey {
        case id, title, weekLabel, kind, questions, sitting, run
        case courseID = "courseId"
        case folderID = "folderId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        courseID = try container.decode(String.self, forKey: .courseID)
        title = try container.decode(String.self, forKey: .title)
        weekLabel = try container.decode(String.self, forKey: .weekLabel)
        folderID = try container.decodeIfPresent(String.self, forKey: .folderID)
        kind = try container.decode(Kind.self, forKey: .kind)
        questions = try container.decode([Question].self, forKey: .questions)
        sitting = try container.decodeIfPresent(Sitting.self, forKey: .sitting)
        run = SetRun.decodeIfPresent(from: container, forKey: .run)
    }
}

/// A question as practice, Review, and exams serve it.
///
/// The server sends the format-specific part as `body`, keyed by `type`. `body` here is that part
/// read into Swift; `rawBody` keeps it exactly as sent, so tables, images, and anything added later
/// survive a trip through the offline cache.
public struct Question: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// The id in the question file, such as `Q3`.
    public let publicID: String
    public let position: Int
    /// The format as the server named it. `type` is nil for a format this version does not know.
    public let typeName: String
    public let topic: String
    /// The NCLEX clinical judgment step, such as "Analyze cues".
    public let clinicalJudgmentStep: String?
    /// The question's own week. Sent on exam questions only.
    public let weekLabel: String?
    public let stem: String
    public let ask: String
    public let rationale: String
    public let takeaway: String
    public let rawBody: JSONValue
    /// The server's checked copies of the body's table and images, kept as sent so they survive
    /// the offline cache. Nil from a server older than them.
    let rawTable: JSONValue?
    let rawImages: JSONValue?
    public let terms: [QuestionTerm]
    /// The format-specific part, read from `rawBody`.
    public let body: QuestionBody

    public var type: QuestionType? { QuestionType(rawValue: typeName) }

    /// The table under the stem, when the question has one that can be drawn.
    public var table: QuestionTable? { QuestionTable(json: rawBody["table"]) }

    /// The images that are safe to draw, at most four.
    public var images: [QuestionImage] { QuestionImage.read(rawBody["images"]) }

    enum CodingKeys: String, CodingKey {
        case id, position, topic, weekLabel, stem, ask, rationale, takeaway, terms
        case publicID = "publicId"
        case typeName = "type"
        case clinicalJudgmentStep = "cj"
        case rawBody = "body"
        case rawTable = "table"
        case rawImages = "images"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        publicID = try container.decode(String.self, forKey: .publicID)
        position = try container.decode(Int.self, forKey: .position)
        typeName = try container.decode(String.self, forKey: .typeName)
        topic = try container.decode(String.self, forKey: .topic)
        clinicalJudgmentStep = try container.decodeIfPresent(String.self, forKey: .clinicalJudgmentStep)
        weekLabel = try container.decodeIfPresent(String.self, forKey: .weekLabel)
        stem = try container.decode(String.self, forKey: .stem)
        ask = try container.decode(String.self, forKey: .ask)
        rationale = try container.decode(String.self, forKey: .rationale)
        takeaway = try container.decode(String.self, forKey: .takeaway)
        rawBody = try container.decode(JSONValue.self, forKey: .rawBody)
        // Read as sent, so a table of null stays null rather than missing.
        rawTable = container.contains(.rawTable) ? try container.decode(JSONValue.self, forKey: .rawTable) : nil
        rawImages = container.contains(.rawImages) ? try container.decode(JSONValue.self, forKey: .rawImages) : nil
        terms = try container.decode([QuestionTerm].self, forKey: .terms)
        do {
            body = try QuestionBody(typeName: typeName, json: rawBody)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .rawBody,
                in: container,
                debugDescription: "Question \(publicID) has a \(typeName) body that cannot be read: \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(publicID, forKey: .publicID)
        try container.encode(position, forKey: .position)
        try container.encode(typeName, forKey: .typeName)
        try container.encode(topic, forKey: .topic)
        try container.encode(clinicalJudgmentStep, forKey: .clinicalJudgmentStep)
        try container.encodeIfPresent(weekLabel, forKey: .weekLabel)
        try container.encode(stem, forKey: .stem)
        try container.encode(ask, forKey: .ask)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(takeaway, forKey: .takeaway)
        try container.encode(rawBody, forKey: .rawBody)
        try container.encodeIfPresent(rawTable, forKey: .rawTable)
        try container.encodeIfPresent(rawImages, forKey: .rawImages)
        try container.encode(terms, forKey: .terms)
    }
}

/// A term a question uses, with its definition.
public struct QuestionTerm: Codable, Sendable, Equatable {
    public let key: String
    public let term: String
    public let meaning: String
}

/// The format-specific part of a question. Indexes in an answer refer to these arrays as stored,
/// never to the shuffled order she sees.
public enum QuestionBody: Sendable, Equatable {
    case single(options: [QuestionOption])
    case priority(options: [QuestionOption])
    case sata(options: [QuestionOption])
    case highlight(segments: [QuestionOption])
    /// The array is the correct order.
    case order(items: [OrderItem])
    case match(pairs: [MatchPair], extra: [MatchExtra])
    case matrix(columns: [String], rows: [MatrixRow])
    case matrixmulti(columns: [String], rows: [MatrixMultiRow])
    case cloze(Cloze)
    /// A format added to the server after this version of the app.
    case unsupported(typeName: String)

    public var type: QuestionType? {
        switch self {
        case .single: .single
        case .priority: .priority
        case .sata: .sata
        case .highlight: .highlight
        case .order: .order
        case .match: .match
        case .matrix: .matrix
        case .matrixmulti: .matrixmulti
        case .cloze: .cloze
        case .unsupported: nil
        }
    }

    init(typeName: String, json: JSONValue) throws {
        guard let type = QuestionType(rawValue: typeName) else {
            self = .unsupported(typeName: typeName)
            return
        }
        let raw = try json.decode(RawBody.self)
        func required<T>(_ value: T?, _ field: String) throws -> T {
            guard let value else { throw RawBody.Missing(field: field) }
            return value
        }
        switch type {
        case .single: self = .single(options: try required(raw.options, "options"))
        case .priority: self = .priority(options: try required(raw.options, "options"))
        case .sata: self = .sata(options: try required(raw.options, "options"))
        case .highlight: self = .highlight(segments: try required(raw.segments, "segments"))
        case .order: self = .order(items: try required(raw.items, "items"))
        case .match: self = .match(pairs: try required(raw.pairs, "pairs"), extra: raw.extra ?? [])
        case .matrix:
            self = .matrix(columns: try required(raw.columns, "columns"), rows: try Self.rows(MatrixRow.self, in: json))
        case .matrixmulti:
            self = .matrixmulti(columns: try required(raw.columns, "columns"), rows: try Self.rows(MatrixMultiRow.self, in: json))
        case .cloze: self = .cloze(try required(raw.cloze, "cloze"))
        }
    }

    /// Rows are read only after the type is known. A matrix row's answer is one column name, and a
    /// matrixmulti row's answer is a list, so the two cannot share one decoder.
    private static func rows<T: Decodable>(_: T.Type, in json: JSONValue) throws -> [T] {
        guard let value = json["rows"] else { throw RawBody.Missing(field: "rows") }
        return try value.decode([T].self)
    }

    private struct RawBody: Decodable {
        struct Missing: Error, CustomStringConvertible {
            let field: String
            var description: String { "missing \"\(field)\"" }
        }

        let options: [QuestionOption]?
        let segments: [QuestionOption]?
        let items: [OrderItem]?
        let pairs: [MatchPair]?
        let extra: [MatchExtra]?
        let columns: [String]?
        let cloze: Cloze?
    }
}

/// An option of a single, priority, or select-all question, or a tappable phrase of a highlight question.
public struct QuestionOption: Codable, Sendable, Equatable {
    public let text: String
    public let isCorrect: Bool
    /// Why it is right or wrong, shown after she checks.
    public let why: String?

    public init(text: String, isCorrect: Bool, why: String? = nil) {
        self.text = text
        self.isCorrect = isCorrect
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case isCorrect = "ok"
        case why
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isCorrect = try container.decodeIfPresent(Bool.self, forKey: .isCorrect) ?? false
        why = try container.decodeIfPresent(String.self, forKey: .why)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if isCorrect { try container.encode(true, forKey: .isCorrect) }
        try container.encodeIfPresent(why, forKey: .why)
    }
}

/// One step of an ordering question.
public struct OrderItem: Codable, Sendable, Equatable {
    public let text: String
    public let why: String?

    public init(text: String, why: String? = nil) {
        self.text = text
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case why
    }
}

/// A left item and the right-hand text that matches it.
public struct MatchPair: Codable, Sendable, Equatable {
    public let left: String
    public let right: String
    public let why: String?

    public init(left: String, right: String, why: String? = nil) {
        self.left = left
        self.right = right
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case left = "l"
        case right = "r"
        case why
    }
}

/// A right-hand choice that matches no left item.
public struct MatchExtra: Codable, Sendable, Equatable {
    public let right: String
    public let why: String?

    public init(right: String, why: String? = nil) {
        self.right = right
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case right = "r"
        case why
    }
}

/// One matrix row where several columns can be right. `answers` are the column names that fit.
public struct MatrixMultiRow: Codable, Sendable, Equatable {
    public let text: String
    public let answers: [String]
    public let why: String?

    public init(text: String, answers: [String], why: String? = nil) {
        self.text = text
        self.answers = answers
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case answers = "ans"
        case why
    }
}

/// One matrix row. `answer` is the column name that is right for it.
public struct MatrixRow: Codable, Sendable, Equatable {
    public let text: String
    public let answer: String
    public let why: String?

    public init(text: String, answer: String, why: String? = nil) {
        self.text = text
        self.answer = answer
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case text = "t"
        case answer = "ans"
        case why
    }
}

/// A drop-down question: `text` holds one `{0}`, `{1}`, ... placeholder per blank.
public struct Cloze: Codable, Sendable, Equatable {
    public let text: String
    public let blanks: [ClozeBlank]

    public init(text: String, blanks: [ClozeBlank]) {
        self.text = text
        self.blanks = blanks
    }
}

/// One drop-down blank. `answer` is the index of the right entry in `options`.
public struct ClozeBlank: Codable, Sendable, Equatable {
    public let options: [String]
    public let answer: Int
    public let why: String?

    public init(options: [String], answer: Int, why: String? = nil) {
        self.options = options
        self.answer = answer
        self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case options = "opts"
        case answer = "ans"
        case why
    }
}
