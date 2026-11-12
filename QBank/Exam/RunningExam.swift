import QBankKit

/// Whether the account has an exam running, as the app last read it. Starting an exam ends the
/// running one, so Start stays off while this is unknown, asks first while one runs, and tells the
/// server which exam it agreed to end. A read that has not come back, or failed, is unknown, never
/// "none".
enum RunningExam: Equatable {
    case unknown
    case none
    case running(ExamSummary)

    init(_ inProgress: ExamSummary?) {
        self = inProgress.map(RunningExam.running) ?? .none
    }

    var isKnown: Bool {
        self != .unknown
    }

    /// The running exam, when one is known.
    var exam: ExamSummary? {
        if case .running(let exam) = self { return exam }
        return nil
    }
}
