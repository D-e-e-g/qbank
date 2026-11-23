#if DEBUG
import Foundation
import QBankKit

/// The fake server's `planExam`: how many questions an exam over the ticked folders takes from each,
/// and its time. It is QBankKit's own `ExamPlanner`, the port of the server's rules that the on-phone
/// bank answers with, so a UI test sees the exams the server would give. The app shows the plan the
/// server sends; only the fake, playing the server, works it out.
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
    static let rules = ExamPlanner.rules

    let questionCount: Int
    let timeLimitSeconds: Int
    let draws: [Draw]

    init(_ pools: [Pool], rules: ExamRules = Self.rules) {
        let plan = ExamPlanner.plan(pools.map { ExamPlanner.Pool(label: $0.id, questionCount: $0.questionCount) }, rules: rules)
        questionCount = plan.questionCount
        timeLimitSeconds = plan.timeLimitSeconds
        draws = zip(pools, plan.draws).map { Draw(id: $0.id, name: $0.name, questionCount: $1.questionCount, drawn: $1.drawn) }
    }
}
#endif
