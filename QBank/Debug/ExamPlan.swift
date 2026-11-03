#if DEBUG
import Foundation
import QBankKit

/// The fake server's `planExam` (`packages/questions/src/exam.ts`): how many questions an exam
/// over the ticked folders takes from each, and its time. The app shows the plan the server sends;
/// only the fake, playing the server, works it out.
///
/// Up to 40 questions in 60 minutes. When the folders hold fewer than 40, the exam is all of them
/// at 1.5 minutes each. A larger pool is split in proportion to each folder's size by largest
/// remainder, so folders holding 22, 27, and 37 give 10 + 13 + 17. A folder with questions always
/// gives at least one, so every ticked folder stays represented.
nonisolated struct ExamPlan: Equatable {
    /// A ticked folder with the questions it holds.
    struct Pool: Equatable {
        let id: String
        let name: String
        let questionCount: Int
    }

    /// One row per ticked folder, in the order given.
    struct Draw: Equatable {
        let id: String
        let name: String
        let questionCount: Int
        /// How many of the folder's questions the exam takes.
        let drawn: Int
    }

    /// The rules the fake server plans by and sends as `ExamSetup.rules`.
    static let rules = ExamRules(maxQuestions: 40, fullTimeSeconds: 60 * 60, secondsPerQuestion: 90)

    let questionCount: Int
    let timeLimitSeconds: Int
    let draws: [Draw]

    init(_ pools: [Pool], rules: ExamRules = Self.rules) {
        let sizes = pools.map { max(0, $0.questionCount) }
        let pool = sizes.reduce(0, +)
        let maxQuestions = rules.maxQuestions
        guard pool > maxQuestions else {
            questionCount = pool
            timeLimitSeconds = pool * rules.secondsPerQuestion
            draws = zip(pools, sizes).map { Draw(id: $0.id, name: $0.name, questionCount: $1, drawn: $1) }
            return
        }

        let quotas = sizes.map { Double($0 * maxQuestions) / Double(pool) }
        var drawn = quotas.map { Int($0.rounded(.down)) }
        var left = maxQuestions - drawn.reduce(0, +)
        let byRemainder = quotas.indices.sorted { a, b in
            let ra = quotas[a] - quotas[a].rounded(.down), rb = quotas[b] - quotas[b].rounded(.down)
            if ra != rb { return ra > rb }
            if sizes[a] != sizes[b] { return sizes[a] > sizes[b] }
            return a < b
        }
        for index in byRemainder where left > 0 {
            drawn[index] += 1
            left -= 1
        }

        // A small folder next to large ones can round to 0. It borrows one from the folder that is
        // furthest over its share, so the total stays at the most.
        let surplus = { (index: Int) in Double(drawn[index]) - quotas[index] }
        for index in drawn.indices where sizes[index] > 0 && drawn[index] == 0 {
            var lender: Int?
            for other in drawn.indices where drawn[other] > 1 {
                if let current = lender, surplus(other) <= surplus(current) { continue }
                lender = other
            }
            guard let lender else { break }
            drawn[lender] -= 1
            drawn[index] = 1
        }

        questionCount = maxQuestions
        timeLimitSeconds = rules.fullTimeSeconds
        draws = pools.indices.map { Draw(id: pools[$0].id, name: pools[$0].name, questionCount: sizes[$0], drawn: drawn[$0]) }
    }
}
#endif
