import Foundation

/// A submitted answer, in the stored question's indexes, never the shuffled layout's.
///
/// - `single`, `priority`: the index of the option she picked.
/// - `sata`, `highlight`: the indexes she ticked or tapped.
/// - `order`: `positions[i]` is the original item index she placed at position i (top first).
/// - `match`: `choices[i]` is the right-hand text she paired with left item i, or nil.
/// - `matrix`: `choices[i]` is the column name she picked for row i, or nil.
/// - `matrixmulti`: `choices[i]` is the column names she checked for row i. An empty list is a blank row.
/// - `cloze`: `choices[i]` is the option index she picked for blank i, or nil.
public enum AnswerResponse: Codable, Sendable, Equatable, Hashable {
    case single(choice: Int)
    case priority(choice: Int)
    case sata(picks: [Int])
    case highlight(picks: [Int])
    case order(positions: [Int])
    case match(choices: [String?])
    case matrix(choices: [String?])
    case matrixmulti(choices: [[String]])
    case cloze(choices: [Int?])

    public var type: QuestionType {
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
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, choice, picks, positions, choices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(QuestionType.self, forKey: .type)
        switch type {
        case .single: self = .single(choice: try container.decode(Int.self, forKey: .choice))
        case .priority: self = .priority(choice: try container.decode(Int.self, forKey: .choice))
        case .sata: self = .sata(picks: try container.decode([Int].self, forKey: .picks))
        case .highlight: self = .highlight(picks: try container.decode([Int].self, forKey: .picks))
        case .order: self = .order(positions: try container.decode([Int].self, forKey: .positions))
        case .match: self = .match(choices: try container.decode([String?].self, forKey: .choices))
        case .matrix: self = .matrix(choices: try container.decode([String?].self, forKey: .choices))
        case .matrixmulti: self = .matrixmulti(choices: try container.decode([[String]].self, forKey: .choices))
        case .cloze: self = .cloze(choices: try container.decode([Int?].self, forKey: .choices))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .single(let choice), .priority(let choice): try container.encode(choice, forKey: .choice)
        case .sata(let picks), .highlight(let picks): try container.encode(picks, forKey: .picks)
        case .order(let positions): try container.encode(positions, forKey: .positions)
        case .match(let choices), .matrix(let choices): try container.encode(choices, forKey: .choices)
        case .matrixmulti(let choices): try container.encode(choices, forKey: .choices)
        case .cloze(let choices): try container.encode(choices, forKey: .choices)
        }
    }
}

/// The order she saw a question in. Saved with the attempt as `shuffle`, so a result screen can
/// show her answer the way she saw it. Same shape as the web runner's layout.
public enum Layout: Codable, Sendable, Equatable, Hashable {
    /// Single, priority, select-all: original option indexes in the order shown.
    case options(order: [Int])
    /// Ordering: original item indexes in the order the question opened.
    case order(start: [Int])
    /// Matching: right-hand texts, distractors included, in the order shown.
    case match(choices: [String])
    /// Drop-down: for each blank, original option indexes in the order the menu shows them.
    case cloze(blanks: [[Int]])
    /// Highlight and matrix keep their stored order.
    case plain

    private enum CodingKeys: String, CodingKey {
        case kind, order, start, choices, blanks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "options": self = .options(order: try container.decode([Int].self, forKey: .order))
        case "order": self = .order(start: try container.decode([Int].self, forKey: .start))
        case "match": self = .match(choices: try container.decode([String].self, forKey: .choices))
        case "cloze": self = .cloze(blanks: try container.decode([[Int]].self, forKey: .blanks))
        case "plain": self = .plain
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown layout kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .options(let order):
            try container.encode("options", forKey: .kind)
            try container.encode(order, forKey: .order)
        case .order(let start):
            try container.encode("order", forKey: .kind)
            try container.encode(start, forKey: .start)
        case .match(let choices):
            try container.encode("match", forKey: .kind)
            try container.encode(choices, forKey: .choices)
        case .cloze(let blanks):
            try container.encode("cloze", forKey: .kind)
            try container.encode(blanks, forKey: .blanks)
        case .plain:
            try container.encode("plain", forKey: .kind)
        }
    }

    /// A fresh shuffle for one opening of a question, as the web runner makes it.
    /// An ordering question never opens already in the right order.
    public static func make(for body: QuestionBody, using generator: inout some RandomNumberGenerator) -> Layout {
        switch body {
        case .single(let options), .priority(let options), .sata(let options):
            return .options(order: Array(options.indices).shuffled(using: &generator))
        case .order(let items):
            let start = Array(items.indices).shuffled(using: &generator)
            let alreadyRight = start.enumerated().allSatisfy { $0.offset == $0.element }
            return .order(start: alreadyRight ? start.reversed() : start)
        case .match(let pairs, let extra):
            return .match(choices: (pairs.map(\.right) + extra.map(\.right)).shuffled(using: &generator))
        case .cloze(let cloze):
            return .cloze(blanks: cloze.blanks.map { Array($0.options.indices).shuffled(using: &generator) })
        case .highlight, .matrix, .matrixmulti, .unsupported:
            return .plain
        }
    }

    public static func make(for body: QuestionBody) -> Layout {
        var generator = SystemRandomNumberGenerator()
        return make(for: body, using: &generator)
    }
}
