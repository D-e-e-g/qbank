import Foundation
import QBankKit

/// The set result, counted the way the web's result screen counts it.
nonisolated struct PracticeResult: Equatable {
    /// One clinical judgment step and how many of its questions were fully right.
    struct Step: Equatable {
        let label: String
        let right: Int
        let total: Int
    }

    /// One question in the result list.
    struct Row: Equatable {
        /// 1-based, in the order she practiced.
        let number: Int
        let question: Question
        let feedback: Feedback?
        let guessed: Bool

        var score: Score? { feedback?.score }

        /// The topic, or the question's id when it has none.
        var title: String { question.topic.isEmpty ? question.publicID : question.topic }

        /// "Select all that apply · 1 of 3".
        var detail: String {
            let format = Wording.format(question.type)
            guard let score else { return format }
            return "\(format) · \(score.points) of \(score.maxPoints)"
        }

        /// "Correct", "Guessed - Partly correct", or "Not answered".
        var mark: String {
            guard let feedback else { return "Not answered" }
            return guessed ? "Guessed - \(feedback.label)" : feedback.label
        }
    }

    let title: String
    /// A run through the Review list rather than a set.
    let isReview: Bool
    let questionCount: Int
    let fullyRight: Int
    let partial: Int
    let missed: Int
    let guessed: Int
    let points: Int
    let maxPoints: Int
    /// How long the run took, in seconds.
    let elapsed: TimeInterval
    /// In the order the steps first appear in the set.
    let steps: [Step]
    let rows: [Row]

    init(title: String, isReview: Bool = false, questions: [Question], attempts: [PracticeModel.Attempt], elapsed: TimeInterval) {
        let verdicts = questions.indices.map { attempts.indices.contains($0) ? attempts[$0].feedback : nil }
        let scores = verdicts.map { $0?.score }
        let guesses = questions.indices.map { attempts.indices.contains($0) && attempts[$0].guessed }
        self.title = title
        self.isReview = isReview
        self.elapsed = elapsed
        questionCount = questions.count
        fullyRight = scores.count { $0?.status == .correct }
        partial = scores.count { $0?.status == .partial }
        missed = scores.count { $0?.status == .incorrect }
        guessed = zip(scores, guesses).count { $0 != nil && $1 }
        points = scores.reduce(0) { $0 + ($1?.points ?? 0) }
        maxPoints = scores.reduce(0) { $0 + ($1?.maxPoints ?? 0) }

        var order: [String] = []
        var counts: [String: (right: Int, total: Int)] = [:]
        for (question, score) in zip(questions, scores) {
            let label = question.clinicalJudgmentStep.flatMap { $0.isEmpty ? nil : $0 } ?? "Not labeled"
            if counts[label] == nil { order.append(label) }
            var count = counts[label] ?? (0, 0)
            count.total += 1
            if score?.status == .correct { count.right += 1 }
            counts[label] = count
        }
        steps = order.map { Step(label: $0, right: counts[$0]?.right ?? 0, total: counts[$0]?.total ?? 0) }
        rows = questions.indices.map { Row(number: $0 + 1, question: questions[$0], feedback: verdicts[$0], guessed: guesses[$0]) }
    }
}
