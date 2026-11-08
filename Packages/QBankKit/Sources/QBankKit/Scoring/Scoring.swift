import Foundation

// The server's scoring rules (`packages/questions/src/score.ts`), so an answer given without
// signal shows the same mark on the phone that the server records when it is sent.

/// The result of scoring one question. `points` is never below 0 or above `maxPoints`.
public struct Score: Sendable, Equatable {
    public let points: Int
    public let maxPoints: Int
    public let status: ScoreStatus
    /// False when she skipped the question or never reached it. An empty submission is still answered.
    public let answered: Bool

    public init(points: Int, maxPoints: Int, status: ScoreStatus, answered: Bool) {
        self.points = points
        self.maxPoints = maxPoints
        self.status = status
        self.answered = answered
    }

    /// The score the server gave a saved answer. The screens show this one, never their own.
    public init(_ saved: SavedAttempt) {
        self.init(points: saved.points, maxPoints: saved.maxPoints, status: saved.status, answered: true)
    }

    /// The banner word: Correct, Partly correct, Not correct, or Not answered.
    public var label: String {
        guard answered else { return "Not answered" }
        switch status {
        case .correct: return "Correct"
        case .partial: return "Partly correct"
        case .incorrect: return "Not correct"
        }
    }

    /// "N of M points" for a submitted multi-part answer. Single-answer and priority questions
    /// show no point line, and neither does a question she did not answer.
    public func pointsText(for type: QuestionType) -> String? {
        guard answered, type != .single, type != .priority else { return nil }
        return "\(points) of \(maxPoints) points"
    }

    /// Whether this answer keeps the question in Review. A guess stays even when fully right;
    /// a question she did not answer never enters Review.
    public func staysInReview(guessed: Bool) -> Bool {
        answered && (guessed || status != .correct)
    }
}

/// The verdict under a checked question: its score and the banner's words, the mark, the points
/// of a multi-part answer and how the format is scored. The words are the server's, as the web
/// shows them; the phone writes its own only for a score it gave itself, while the answer waits
/// to be sent or for a sample that is never sent.
public struct Feedback: Sendable, Equatable {
    public let score: Score
    /// Correct, Partly correct, or Not correct.
    public let label: String
    /// "1 of 3 points", or nil for single answer and priority.
    public let pointsText: String?
    /// How the format is scored, or nil for the formats that add no rule.
    public let ruleText: String?

    /// The server's score and words for a saved answer.
    public init(_ saved: SavedAttempt) {
        score = Score(saved)
        label = saved.label
        pointsText = saved.pointsText
        ruleText = saved.ruleText
    }

    /// The server's score and words for an answer of a set's sitting.
    public init(_ answer: SittingAnswer) {
        score = Score(points: answer.points, maxPoints: answer.maxPoints, status: answer.status, answered: true)
        label = answer.label
        pointsText = answer.pointsText
        ruleText = answer.ruleText
    }

    /// The phone's words for a score it gave, worded as the server words them.
    public init(phone score: Score, type: QuestionType?) {
        self.score = score
        label = score.label
        pointsText = type.flatMap(score.pointsText(for:))
        ruleText = type?.scoringRule
    }
}

/// An answer in a different format from its question, or a question format this version cannot score.
public struct ScoringError: Error, Sendable, Equatable {
    public let message: String
}

public enum Scoring {
    /// Scores one question. Pass nil for a question she skipped or never reached.
    ///
    /// The maximum is 1 for single and priority, the number of correct options for select-all and
    /// highlight, the number of correct boxes for a matrix where a row can fit more than one
    /// column, and one point per item, pair, row, or blank for the rest. A wrong, empty, or
    /// out-of-range answer is scored; only an answer in another format throws.
    public static func score(_ body: QuestionBody, response: AnswerResponse?) throws(ScoringError) -> Score {
        let maxPoints = try maximum(for: body)
        guard let response else {
            return Score(points: 0, maxPoints: maxPoints, status: status(0, maxPoints), answered: false)
        }
        let points = min(maxPoints, try earned(body, response))
        return Score(points: points, maxPoints: maxPoints, status: status(points, maxPoints), answered: true)
    }

    private static func status(_ points: Int, _ maxPoints: Int) -> ScoreStatus {
        if points == maxPoints { return .correct }
        if points > 0 { return .partial }
        return .incorrect
    }

    private static func maximum(for body: QuestionBody) throws(ScoringError) -> Int {
        switch body {
        case .single, .priority: 1
        case .sata(let options): options.count(where: \.isCorrect)
        case .highlight(let segments): segments.count(where: \.isCorrect)
        case .order(let items): items.count
        case .match(let pairs, _): pairs.count
        case .matrix(_, let rows): rows.count
        case .matrixmulti(let columns, let rows): matrixBoxes(columns: columns, rows: rows).count(where: \.isCorrect)
        case .cloze(let cloze): cloze.blanks.count
        case .unsupported(let typeName): throw ScoringError(message: "Cannot score a \(typeName) question.")
        }
    }

    private static func earned(_ body: QuestionBody, _ response: AnswerResponse) throws(ScoringError) -> Int {
        switch (body, response) {
        case (.single(let options), .single(let choice)), (.priority(let options), .priority(let choice)):
            return options.indices.contains(choice) && options[choice].isCorrect ? 1 : 0
        case (.sata(let options), .sata(let picks)), (.highlight(let options), .highlight(let picks)):
            return plusMinus(options, picks)
        case (.order(let items), .order(let positions)):
            return zip(positions.prefix(items.count), 0...).count { $0 == $1 }
        case (.match(let pairs, _), .match(let choices)):
            return exact(pairs.map(\.right), choices)
        case (.matrix(_, let rows), .matrix(let choices)):
            return exact(rows.map(\.answer), choices)
        case (.matrixmulti(let columns, let rows), .matrixmulti(let choices)):
            return plusMinus(matrixBoxes(columns: columns, rows: rows), matrixPicks(columns: columns, rowCount: rows.count, choices: choices))
        case (.cloze(let cloze), .cloze(let choices)):
            return exact(cloze.blanks.map(\.answer), choices)
        default:
            let expected = body.type?.rawValue ?? "unknown"
            throw ScoringError(message: "Cannot score a \(expected) question with a \(response.type.rawValue) answer.")
        }
    }

    // +1 for each correct option picked, -1 for each wrong one, never below 0.
    // A repeated index counts once, so it cannot raise the score.
    private static func plusMinus(_ options: [QuestionOption], _ picks: [Int]) -> Int {
        var seen = Set<Int>()
        var good = 0
        var bad = 0
        for index in picks where seen.insert(index).inserted {
            if options.indices.contains(index) && options[index].isCorrect {
                good += 1
            } else {
                bad += 1
            }
        }
        return max(0, good - bad)
    }

    private static func exact<T: Equatable>(_ expected: [T], _ choices: [T?]) -> Int {
        expected.indices.count { index in index < choices.count && choices[index] == expected[index] }
    }

    /// One option per box, in row order, so the select-all rule scores the table.
    private static func matrixBoxes(columns: [String], rows: [MatrixMultiRow]) -> [QuestionOption] {
        rows.flatMap { row in
            let right = Set(row.answers)
            return columns.map { QuestionOption(text: $0, isCorrect: right.contains($0)) }
        }
    }

    /// The box index of each column she checked. A repeated name on a row counts once.
    /// A name that is not a column is a wrong box, and a row past the table is ignored.
    private static func matrixPicks(columns: [String], rowCount: Int, choices: [[String]]) -> [Int] {
        let width = columns.count
        var picks: [Int] = []
        var unknown: [String: Int] = [:]
        var extra = rowCount * width
        for row in 0..<min(choices.count, rowCount) {
            for name in choices[row] {
                if let column = columns.firstIndex(of: name) {
                    picks.append(row * width + column)
                    continue
                }
                let key = "\(row)\u{0000}\(name)"
                if let known = unknown[key] {
                    picks.append(known)
                    continue
                }
                unknown[key] = extra
                picks.append(extra)
                extra += 1
            }
        }
        return picks
    }
}

extension QuestionType {
    /// The scoring rule the feedback banner explains under the points. Select-all and highlight
    /// share one sentence. A matrix where a row can fit more than one column has the same rule,
    /// in the words of a box. Ordering has its own. The other formats score a point per part and
    /// add none.
    public var scoringRule: String? {
        switch self {
        case .sata, .highlight: "+1 for each correct choice, -1 for each wrong one"
        case .matrixmulti: "+1 for each correct box, -1 for each wrong one"
        case .order: "items in the right position; full credit needs all of them"
        case .single, .priority, .match, .matrix, .cloze: nil
        }
    }
}
