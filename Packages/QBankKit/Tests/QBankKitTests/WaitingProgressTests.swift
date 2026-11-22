import Foundation
import Testing
@testable import QBankKit

@Suite("Waiting answers counted into progress")
struct WaitingProgressTests {
    static let day = Date(timeIntervalSince1970: 1_790_000_000)

    static func set(
        _ id: String, questions: Int, answered: Int = 0, right: Int = 0, lastAnsweredAt: Date? = nil
    ) -> PracticeSetSummary {
        PracticeSetSummary(
            id: id, title: "Invented \(id)", description: "", questionCount: questions,
            importedAt: day, activeSince: day, status: .imported, canRestore: false,
            answeredCount: answered, fullyRightCount: right, lastAnsweredAt: lastAnsweredAt,
            questionIDs: (0..<questions).map { "\(id)-q\($0)" }, importedByAgent: nil
        )
    }

    static func course(_ sets: [PracticeSetSummary], answered: Int, right: Int, questions: Int = 86) -> CourseDetail {
        CourseDetail(
            id: "c1", code: "NURS 101", title: "Invented Basics", archivedAt: nil,
            semester: .init(id: "s1", number: 1, name: "Semester 1"),
            questionCount: questions, examQuestionCount: 0, weekCount: 1, termCount: 0,
            reviewCount: 0, answeredCount: answered, fullyRightCount: right, points: 7, maxPoints: 9,
            weeks: [Week(label: "Week 1", sets: sets, examBankCount: 0)],
            exams: [CourseExam(id: "x1", name: "Exam 1", sortOrder: 1, weekLabels: ["Week 1"])]
        )
    }

    static func summary(answered: Int, right: Int, questions: Int) -> CourseSummary {
        CourseSummary(
            id: "c1", code: "NURS 101", title: "Invented Basics", sortOrder: 1, archivedAt: nil,
            questionCount: questions, weekCount: 1, reviewCount: 0, answeredCount: answered, fullyRightCount: right,
            points: 7, maxPoints: 9
        )
    }

    static func waiting(_ answers: [(String, ScoreStatus?, Double)]) -> WaitingProgress {
        WaitingProgress(
            answers: Dictionary(
                uniqueKeysWithValues: answers.map {
                    ($0.0, WaitingProgress.Answer(status: $0.1, answeredAt: day.addingTimeInterval($0.2)))
                }))
    }

    @Test func aSetSheHadNotAnsweredCountsEveryWaitingAnswer() {
        let progress = Self.waiting([("a-q0", .correct, 10), ("a-q1", .partial, 20), ("b-q0", .correct, 30)])
        let counted = progress.counting(Self.set("a", questions: 4))
        #expect(counted.answeredCount == 2)
        #expect(counted.fullyRightCount == 1)
        #expect(counted.lastAnsweredAt == Self.day.addingTimeInterval(20))
        #expect(counted.id == "a")
        #expect(counted.questionIDs == Self.set("a", questions: 4).questionIDs)
    }

    @Test func aSetWithEveryQuestionWaitingTakesItsCountsFromThem() {
        let progress = Self.waiting([("a-q0", .correct, 10), ("a-q1", .incorrect, 20)])
        let counted = progress.counting(Self.set("a", questions: 2, answered: 2, right: 2, lastAnsweredAt: Self.day))
        #expect(counted.answeredCount == 2)
        #expect(counted.fullyRightCount == 1, "her latest answers count, and one of them is wrong now")
        #expect(counted.lastAnsweredAt == Self.day.addingTimeInterval(20))
    }

    @Test func aSetSheHadStartedCountsAtLeastItsWaitingAnswers() {
        let started = Self.set("a", questions: 5, answered: 2, right: 1, lastAnsweredAt: Self.day.addingTimeInterval(100))
        let fewer = Self.waiting([("a-q0", .correct, 10)]).counting(started)
        #expect(fewer.answeredCount == 2, "the waiting answer may be to a question she had answered")
        #expect(fewer.fullyRightCount == 1)
        #expect(fewer.lastAnsweredAt == Self.day.addingTimeInterval(100))

        let more = Self.waiting([("a-q0", .correct, 10), ("a-q1", .correct, 11), ("a-q2", nil, 12)]).counting(started)
        #expect(more.answeredCount == 3)
        #expect(more.fullyRightCount == 1, "the server's count stays when the phone cannot know better")
    }

    @Test func aSetWithoutWaitingAnswersIsUnchanged() {
        let set = Self.set("a", questions: 3, answered: 1, right: 1, lastAnsweredAt: Self.day)
        #expect(Self.waiting([("b-q0", .correct, 0)]).counting(set) == set)
        #expect(WaitingProgress(answers: [:]).counting(set) == set)
    }

    @Test func theLatestWaitingAnswerToAQuestionCounts() {
        func attempt(_ id: String, _ question: String, at seconds: Double) -> PendingAttempt {
            PendingAttempt(
                submission: AttemptSubmission(clientAttemptID: id, questionID: question, response: .single(choice: 0)),
                courseID: "c1", queuedAt: Self.day.addingTimeInterval(seconds)
            )
        }
        let pending = [attempt("x1", "a-q0", at: 1), attempt("x2", "a-q1", at: 2), attempt("x3", "a-q0", at: 3)]
        let progress = WaitingProgress(pending: pending) { $0.id == "x3" ? .incorrect : .correct }
        #expect(progress.answers["a-q0"] == WaitingProgress.Answer(status: .incorrect, answeredAt: Self.day.addingTimeInterval(3)))
        #expect(progress.answers.count == 2)
        let counted = progress.counting(Self.set("a", questions: 3))
        #expect(counted.answeredCount == 2)
        #expect(counted.fullyRightCount == 1)
    }

    @Test func theCourseAddsWhatItsSetsGained() {
        let course = Self.course(
            [
                Self.set("a", questions: 4),
                Self.set("b", questions: 2, answered: 2, right: 2, lastAnsweredAt: Self.day),
            ], answered: 30, right: 20)
        let progress = Self.waiting([("a-q0", .correct, 1), ("a-q1", .correct, 2), ("b-q0", .incorrect, 3), ("b-q1", .incorrect, 4)])
        let counted = progress.counting(course)
        #expect(counted.weeks[0].sets.map(\.answeredCount) == [2, 2])
        #expect(counted.weeks[0].sets.map(\.fullyRightCount) == [2, 0])
        #expect(counted.answeredCount == 32)
        #expect(counted.fullyRightCount == 20, "two new right answers, two right answers now wrong")
        #expect(counted.points == 7, "points stay the server's")
        #expect(counted.weeks[0].label == "Week 1")
        #expect(counted.exams == course.exams, "the course's exams stay")
    }

    @Test func homeCountsTheWaitingAnswersThroughTheSavedCourse() {
        let detail = Self.course([Self.set("a", questions: 4)], answered: 0, right: 0)
        let progress = Self.waiting([("a-q0", .correct, 1), ("a-q1", .partial, 2)])
        let card = progress.counting(Self.summary(answered: 35, right: 24, questions: 86), saved: detail)
        #expect(card.answeredCount == 37)
        #expect(card.fullyRightCount == 25)
        #expect(progress.counting(Self.summary(answered: 35, right: 24, questions: 86), saved: nil).answeredCount == 35)
        #expect(progress.counting(Self.summary(answered: 85, right: 24, questions: 86), saved: detail).answeredCount == 86, "never more than every question")
    }
}
