import Foundation

/// An exam's result from the answers saved on it.
///
/// Every question counts: an unanswered one earns 0 of its maximum and stays out of Review, and so
/// does every exam-bank question.
enum ExamScoring {
    struct Item {
        let questionId: String
        /// `unanswered` for a question skipped or never reached.
        let status: String
        let label: String
        let points: Int
        let maxPoints: Int
        let guessed: Bool
        let response: JSONValue
        let shuffle: JSONValue

        var json: JSONValue {
            .object([
                "questionId": .string(questionId), "status": .string(status), "label": .string(label), "points": .int(points), "maxPoints": .int(maxPoints),
                "guessed": .bool(guessed), "response": response, "shuffle": shuffle,
            ])
        }
    }

    /// A group of questions and how many of them were right.
    struct Tally {
        var label: String
        var right = 0
        var total = 0

        init(_ label: String) { self.label = label }

        var json: JSONValue { .object(["label": .string(label), "right": .int(right), "total": .int(total)]) }
    }

    struct Result {
        let questionCount: Int
        let answered: Int
        let unanswered: Int
        let fullyRight: Int
        let partial: Int
        let missed: Int
        let guessed: Int
        let points: Int
        let maxPoints: Int
        let minutesUsed: Int
        /// Misses and guesses among the practice questions answered: what this exam sent to Review.
        let reviewCount: Int
        /// Exam-bank questions answered not fully right. They stay out of Review; a wrong-questions exam asks them again.
        let examBankWrong: Int
        /// By the folder each question's set is in now, in the course's folder order.
        let byFolder: [JSONValue]
        /// Legacy: by each question's own week.
        let byWeek: [Tally]
        let byStep: [Tally]
        /// In exam order.
        let items: [Item]

        /// What is kept on the exam when it ends, so the past-exam list does not rescan answers.
        var stored: JSONValue {
            .object([
                "questionCount": .int(questionCount), "answered": .int(answered), "fullyRight": .int(fullyRight), "points": .int(points), "maxPoints": .int(maxPoints),
                "minutesUsed": .int(minutesUsed), "reviewCount": .int(reviewCount),
            ])
        }

        var json: JSONValue {
            .object([
                "questionCount": .int(questionCount), "answered": .int(answered), "unanswered": .int(unanswered), "fullyRight": .int(fullyRight), "partial": .int(partial),
                "missed": .int(missed), "guessed": .int(guessed), "points": .int(points), "maxPoints": .int(maxPoints), "minutesUsed": .int(minutesUsed),
                "reviewCount": .int(reviewCount), "examBankWrong": .int(examBankWrong), "byFolder": .array(byFolder), "byWeek": .array(byWeek.map(\.json)),
                "byStep": .array(byStep.map(\.json)), "items": .array(items.map(\.json)),
            ])
        }
    }

    /// The clinical judgment steps in the order they are met.
    private static let stepOrder = ["Recognize cues", "Analyze cues", "Prioritize hypotheses", "Generate solutions", "Take action", "Take actions", "Evaluate outcomes"]
    private static let notLabeled = "Not labeled"

    /// `folders`, in the course's order, name the by-folder rows.
    static func score(_ exam: ExamRow, served: ExamStore.Served, answers: [StoreRow], finishedAt: String, folders: [FolderRow]) throws -> Result {
        var byQuestion: [String: StoreRow] = [:]
        for answer in answers { byQuestion[answer.string("question_id")] = answer }
        var items: [Item] = []
        var byFolder = Tallies()
        var weeks = Tallies(labels: exam.weeks ?? [])
        var steps = Tallies()
        var reviewCount = 0
        var examBankWrong = 0

        for row in served.rows {
            let answer = byQuestion[row.string("id")]
            let status = answer.map { asStatus($0.string("status")) } ?? "unanswered"
            if answer != nil, served.bank.contains(row.string("id")) {
                if status != "correct" { examBankWrong += 1 }
            } else if let answer, score(of: answer).staysInReview(guessed: answer.flag("guessed")) {
                reviewCount += 1
            }
            let points = answer?.integer("points") ?? 0
            let maxPoints = answer?.integer("max_points") ?? maximum(of: row)
            items.append(
                Item(
                    questionId: row.string("id"), status: status,
                    label: Score(points: points, maxPoints: maxPoints, status: ScoreStatus(rawValue: status) ?? .incorrect, answered: answer != nil).label,
                    points: points, maxPoints: maxPoints, guessed: answer?.flag("guessed") ?? false, response: answer.flatMap { json($0, "response") } ?? .null,
                    shuffle: answer.flatMap { json($0, "shuffle") } ?? .null))
            if let folder = served.folderOf[row.string("id")] { byFolder.add(folder, right: status == "correct") }
            weeks.add(row.string("week_label"), right: status == "correct")
            let step = row.text("cj").flatMap { JS.trim($0).isEmpty ? nil : $0 } ?? notLabeled
            steps.add(step, right: status == "correct")
        }

        let answered = items.filter { $0.status != "unanswered" }
        let limit = (exam.limitSeconds ?? 0) * 1000
        let started = ExamClock.milliseconds(exam.startedAt) ?? 0
        let used = min(limit, max(0, (ExamClock.milliseconds(finishedAt) ?? started) - started))
        return Result(
            questionCount: items.count, answered: answered.count, unanswered: items.count - answered.count, fullyRight: items.count { $0.status == "correct" },
            partial: items.count { $0.status == "partial" }, missed: items.count { $0.status == "incorrect" }, guessed: answered.count { $0.guessed },
            points: items.reduce(0) { $0 + $1.points }, maxPoints: items.reduce(0) { $0 + $1.maxPoints },
            minutesUsed: max(1, Int((Double(used) / 60_000).rounded(.toNearestOrAwayFromZero))), reviewCount: reviewCount, examBankWrong: examBankWrong,
            byFolder: folders.compactMap { folder in
                byFolder[folder.id].map { .object(["folderId": .string(folder.id), "label": .string(folder.name), "right": .int($0.right), "total": .int($0.total)]) }
            },
            byWeek: weeks.rows.filter { $0.total > 0 }, byStep: sortedSteps(steps.rows), items: items)
    }

    /// Groups of questions in the order they were first met.
    private struct Tallies {
        private(set) var rows: [Tally] = []
        private var index: [String: Int] = [:]

        init(labels: [String] = []) {
            for label in labels where index[label] == nil { place(label) }
        }

        subscript(_ label: String) -> Tally? { index[label].map { rows[$0] } }

        mutating func add(_ label: String, right: Bool) {
            let at = index[label] ?? place(label)
            rows[at].total += 1
            if right { rows[at].right += 1 }
        }

        @discardableResult
        private mutating func place(_ label: String) -> Int {
            rows.append(Tally(label))
            index[label] = rows.count - 1
            return rows.count - 1
        }
    }

    private static func sortedSteps(_ rows: [Tally]) -> [Tally] {
        rows.enumerated().sorted { a, b in
            let (rankA, rankB) = (stepRank(a.element.label), stepRank(b.element.label))
            return rankA != rankB ? rankA < rankB : a.offset < b.offset
        }.map(\.element)
    }

    private static func stepRank(_ label: String) -> Int {
        if let index = stepOrder.firstIndex(where: { $0.lowercased() == label.lowercased() }) { return index }
        return stepOrder.count + (label == notLabeled ? 1 : 0)
    }

    /// The mark a saved answer earned.
    static func score(of answer: StoreRow) -> Score {
        Score(points: answer.integer("points"), maxPoints: answer.integer("max_points"), status: ScoreStatus(rawValue: answer.string("status")) ?? .incorrect, answered: true)
    }

    private static func asStatus(_ value: String) -> String { value == "correct" || value == "partial" ? value : "incorrect" }

    private static func json(_ row: StoreRow, _ column: String) -> JSONValue? {
        row.text(column).flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    /// The most a question can earn, or 0 for one that cannot be read.
    static func maximum(of question: StoreRow) -> Int {
        guard let node = try? JSParser.parse(question.string("body")), case .object = node,
            let body = try? QuestionBody(typeName: question.string("type"), json: node.json), let score = try? Scoring.score(body, response: nil)
        else { return 0 }
        return score.maxPoints
    }
}
