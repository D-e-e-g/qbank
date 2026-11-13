import Foundation

/// Answers waiting on the phone, counted into the progress the server last reported, so a set she
/// practiced without signal shows her answers before they are sent.
///
/// The server counts each question once, by her latest answer to it. The phone does not know which
/// questions she had answered before, so it never counts more questions answered than she has:
/// - a set she had not answered counts every waiting question, and its fully right ones;
/// - a set whose every question is waiting takes all its counts from the waiting answers, since
///   each is her latest answer;
/// - any other set counts at least its waiting questions and keeps the server's fully right count,
///   which her waiting answers may change once they are sent.
///
/// A set's sitting counts its waiting answers on top of the ones the server reported: the runner
/// asks only questions she has not answered in it. Once they cover the set, the sitting is over, as
/// the server closes it. A waiting Review answer is left out: it counts once the server has it.
///
/// Its run follows: a Done set stays Done, since a retake has nothing to continue; a set whose every
/// question now has an answer is Done; and one whose waiting answers begin or extend a sitting is
/// Midway.
///
/// Points stay as the server reported them.
public struct WaitingProgress: Sendable, Equatable {
    /// The latest waiting answer to one question.
    public struct Answer: Sendable, Equatable {
        /// How the phone scored it, or nil when its question is not saved on the phone.
        public let status: ScoreStatus?
        public let answeredAt: Date
        /// Whether it counts in the set's sitting.
        public let joinsASitting: Bool

        public init(status: ScoreStatus?, answeredAt: Date, joinsASitting: Bool = true) {
            self.status = status
            self.answeredAt = answeredAt
            self.joinsASitting = joinsASitting
        }
    }

    /// The latest waiting answer to each question, by question id.
    public let answers: [String: Answer]

    public init(answers: [String: Answer]) {
        self.answers = answers
    }

    /// - Parameters:
    ///   - pending: The waiting answers, oldest first, as `AttemptQueue.pending` lists them.
    ///   - status: Scores one on the phone, or nil when its question is not saved.
    public init(pending: [PendingAttempt], status: (PendingAttempt) -> ScoreStatus?) {
        var answers: [String: Answer] = [:]
        for attempt in pending {
            let earlier = answers[attempt.submission.questionID]
            answers[attempt.submission.questionID] = Answer(
                status: status(attempt), answeredAt: attempt.queuedAt,
                joinsASitting: attempt.submission.joinsASitting || earlier?.joinsASitting == true
            )
        }
        self.init(answers: answers)
    }

    public var isEmpty: Bool { answers.isEmpty }

    /// The set with its waiting answers counted in.
    public func counting(_ set: PracticeSetSummary) -> PracticeSetSummary {
        let waiting = Set(set.questionIDs).compactMap { answers[$0] }
        guard !waiting.isEmpty else { return set }
        let rightNow = waiting.count { $0.status == .correct }
        let lastAnsweredAt = (waiting.map(\.answeredAt) + [set.lastAnsweredAt].compactMap { $0 }).max()
        let answered: Int
        let fullyRight: Int
        if waiting.count >= set.questionCount {
            answered = set.questionCount
            fullyRight = rightNow
        } else if set.answeredCount == 0 {
            answered = waiting.count
            fullyRight = rightNow
        } else {
            answered = min(set.questionCount, max(set.answeredCount, waiting.count))
            fullyRight = set.fullyRightCount
        }
        let inSitting = waiting.count { $0.joinsASitting }
        let sittingCount = (set.sitting?.answeredCount ?? 0) + inSitting
        let answeredCount = max(answered, min(set.questionCount, sittingCount))
        let run: SetRun
        let sitting: PracticeSetSummary.Sitting?
        if set.run == .done || (set.questionCount > 0 && answeredCount >= set.questionCount) {
            (run, sitting) = (.done, nil)
        } else if inSitting > 0 {
            (run, sitting) = (.midway, PracticeSetSummary.Sitting(answeredCount: sittingCount))
        } else {
            // Only Review answers wait: the sitting stays as it is, and a New set now has answers.
            (run, sitting) = (set.run == .new ? .restarted : set.run, set.sitting)
        }
        return PracticeSetSummary(
            id: set.id, title: set.title, description: set.description, questionCount: set.questionCount,
            importedAt: set.importedAt, activeSince: set.activeSince, status: set.status, canRestore: set.canRestore,
            answeredCount: answeredCount, fullyRightCount: fullyRight, lastAnsweredAt: lastAnsweredAt,
            questionIDs: set.questionIDs, importedByAgent: set.importedByAgent, sitting: sitting, run: run
        )
    }

    /// The course with its waiting answers counted into every set and into the course's own counts.
    public func counting(_ course: CourseDetail) -> CourseDetail {
        guard !isEmpty else { return course }
        let weeks = course.weeks.map { week in
            Week(label: week.label, sets: week.sets.map(counting), examBankCount: week.examBankCount)
        }
        let folders = course.folders.map(counting)
        let (answered, fullyRight) = added(from: course.folders, to: folders)
        return CourseDetail(
            id: course.id, kind: course.kind, code: course.code, title: course.title, archivedAt: course.archivedAt,
            semester: course.semester, questionCount: course.questionCount, examQuestionCount: course.examQuestionCount,
            weekCount: course.weekCount, termCount: course.termCount, reviewCount: course.reviewCount,
            answeredCount: Self.clamp(course.answeredCount + answered, to: course.questionCount),
            fullyRightCount: Self.clamp(course.fullyRightCount + fullyRight, to: course.questionCount),
            points: course.points, maxPoints: course.maxPoints, weeks: weeks, exams: course.exams, folders: folders,
            folderCount: course.folderCount, examTimeLimitSeconds: course.examTimeLimitSeconds
        )
    }

    /// A Home course card with its waiting answers counted in, using the course's saved folders and
    /// sets. Unchanged without them.
    public func counting(_ course: CourseSummary, saved detail: CourseDetail?) -> CourseSummary {
        guard !isEmpty, let detail, detail.id == course.id else { return course }
        let (answered, fullyRight) = added(from: detail.folders, to: detail.folders.map(counting))
        return CourseSummary(
            id: course.id, kind: course.kind, code: course.code, title: course.title, sortOrder: course.sortOrder,
            archivedAt: course.archivedAt, questionCount: course.questionCount, weekCount: course.weekCount,
            folderCount: course.folderCount, reviewCount: course.reviewCount,
            answeredCount: Self.clamp(course.answeredCount + answered, to: course.questionCount),
            fullyRightCount: Self.clamp(course.fullyRightCount + fullyRight, to: course.questionCount),
            points: course.points, maxPoints: course.maxPoints
        )
    }

    private func counting(_ folder: Folder) -> Folder {
        Folder(
            id: folder.id, name: folder.name, examPageID: folder.examPageID, sortOrder: folder.sortOrder,
            sets: folder.sets.map(counting), examBankCount: folder.examBankCount, examSets: folder.examSets
        )
    }

    /// How many answered and fully right questions counting the waiting answers adds across the sets.
    private func added(from before: [Folder], to after: [Folder]) -> (answered: Int, fullyRight: Int) {
        let pairs = zip(before.flatMap(\.sets), after.flatMap(\.sets))
        return pairs.reduce(into: (0, 0)) { total, pair in
            total.0 += pair.1.answeredCount - pair.0.answeredCount
            total.1 += pair.1.fullyRightCount - pair.0.fullyRightCount
        }
    }

    private static func clamp(_ value: Int, to limit: Int) -> Int {
        min(max(0, value), max(0, limit))
    }
}
