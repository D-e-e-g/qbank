import Foundation
import QBankKit

/// Whether the account has an exam that has not ended, as the app last read it. Starting an exam
/// ends that one, so Start stays off while this is unknown, asks first while one is open, and tells
/// the server which exam it agreed to end. A read that has not come back, or failed, is unknown,
/// never "none".
enum RunningExam: Equatable {
    case unknown
    case none
    /// Running, or in its grace (`ExamStatus`) when it was read.
    case running(ExamSummary)

    init(_ inProgress: ExamSummary?) {
        self = inProgress.map(RunningExam.running) ?? .none
    }

    var isKnown: Bool {
        self != .unknown
    }

    /// The exam that has not ended, when one is known.
    var exam: ExamSummary? {
        if case .running(let exam) = self { return exam }
        return nil
    }

    /// The exam that is still open at `date`: running, or in its grace, when the server still asks
    /// before ending it. One whose time is up since it was read has ended, and is not asked about.
    func exam(at date: Date) -> ExamSummary? {
        exam.flatMap { $0.status(at: date) == .ended ? nil : $0 }
    }
}
