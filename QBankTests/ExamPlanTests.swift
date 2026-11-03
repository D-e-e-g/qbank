import QBankKit
import Testing
@testable import QBank

/// The fake server's plan held to the server's `planExam` cases (`packages/questions/src/exam.test.ts`),
/// so the UI tests see the exams the server would give, and the web's exam wording
/// (`apps/web/src/exam/weeks.test.ts`).
struct ExamPlanTests {
    private func plan(_ sizes: [Int]) -> ExamPlan {
        ExamPlan(sizes.enumerated().map { ExamPlan.Pool(id: "f\($0.offset + 1)", name: "Week \($0.offset + 1)", questionCount: $0.element) })
    }

    @Test func splitsFortyInProportion() {
        let plan = plan([22, 27, 37])
        #expect(plan.draws.map(\.drawn) == [10, 13, 17])
        #expect(plan.questionCount == 40)
        #expect(plan.timeLimitSeconds == 60 * 60)
        #expect(plan.draws.map(\.name) == ["Week 1", "Week 2", "Week 3"])
        #expect(plan.draws.map(\.id) == ["f1", "f2", "f3"])
    }

    @Test func takesAllOfThemWhenTheFoldersHoldFewerThanForty() {
        let plan = plan([12, 10])
        #expect(plan.draws.map(\.drawn) == [12, 10])
        #expect(plan.questionCount == 22)
        #expect(plan.timeLimitSeconds == 33 * 60)
    }

    @Test func takesExactlyFortyInAnHour() {
        let plan = plan([25, 15])
        #expect(plan.draws.map(\.drawn) == [25, 15])
        #expect(plan.timeLimitSeconds == 60 * 60)
    }

    @Test func keepsASmallFolderRepresented() {
        #expect(plan([1, 200]).draws.map(\.drawn) == [1, 39])
    }

    @Test func alwaysAddsUpToFortyAndNeverTakesMoreThanAFolderHolds() {
        let sizes = [3, 41, 7, 19, 1, 88, 2]
        let plan = plan(sizes)
        #expect(plan.draws.map(\.drawn).reduce(0, +) == 40)
        for (folder, size) in zip(plan.draws, sizes) {
            #expect(folder.drawn > 0)
            #expect(folder.drawn <= size)
        }
    }

    @Test func breaksAnEvenSplitTheSameWayEveryTime() {
        #expect(plan([30, 30, 30]).draws.map(\.drawn) == [14, 13, 13])
        #expect(plan([30, 30, 30]).draws.map(\.drawn) == [14, 13, 13])
    }

    @Test func plansByTheRulesItIsGiven() {
        let rules = ExamRules(maxQuestions: 25, fullTimeSeconds: 1800, secondsPerQuestion: 60)
        let pools = [10, 30].enumerated().map { ExamPlan.Pool(id: "f\($0.offset + 1)", name: "Week \($0.offset + 1)", questionCount: $0.element) }
        let plan = ExamPlan(pools, rules: rules)
        #expect(plan.draws.map(\.drawn) == [6, 19])
        #expect(plan.questionCount == 25)
        #expect(plan.timeLimitSeconds == 1800)
        #expect(ExamPlan(Array(pools.prefix(1)), rules: rules).timeLimitSeconds == 600)
    }

    @Test func drawsNothingFromNothing() {
        #expect(plan([]) == ExamPlan([]))
        #expect(plan([]).questionCount == 0)
        #expect(plan([]).timeLimitSeconds == 0)
        #expect(plan([0]).draws.map(\.drawn) == [0])
    }

    // MARK: Wording

    @Test func foldersAreNamedAndPlainWeekNumbersJoinInRuns() {
        #expect(Wording.folders(["Week 1", "Week 2", "Week 3"]) == "Weeks 1-3")
        #expect(Wording.folders(["Week 4", "Week 1", "Week 2"]) == "Weeks 1-2, 4")
        #expect(Wording.folders(["Week 2"]) == "Week 2")
        #expect(Wording.folders(["Week 1", "Weeks 3-4"]) == "Week 1, Weeks 3-4")
        #expect(Wording.folders(["First Pass", "Exam 2 - Week 4"]) == "First Pass, Exam 2 - Week 4")
        #expect(Wording.folders([]) == "")
    }

    @Test func minutesShowWholeAndHalfMinutes() {
        #expect(Wording.minutes(seconds: 3600) == "60 minutes")
        #expect(Wording.minutes(seconds: 33 * 60) == "33 minutes")
        #expect(Wording.minutes(seconds: 7 * 90) == "10.5 minutes")
        #expect(Wording.minutes(seconds: 90) == "1.5 minutes")
        #expect(Wording.minutes(seconds: 60) == "1 minute")
    }

    @Test func practiceFoldersAreNamedBeforeAndAfter() {
        #expect(Wording.practiceFolders(["Week 3"], before: true) == "Week 3 has no exam bank yet, so it uses its practice questions.")
        #expect(Wording.practiceFolders(["Week 1", "Week 2"], before: true) == "Weeks 1-2 have no exam bank yet, so they use their practice questions.")
        #expect(Wording.practiceFolders(["Week 3"], before: false) == "Week 3 had no exam bank, so its questions came from practice sets.")
        #expect(Wording.practiceFolders(["Week 1", "Weeks 3-4"], before: false) == "Week 1, Weeks 3-4 had no exam bank, so their questions came from practice sets.")
        #expect(Wording.practiceFolders(["First Pass"], before: true) == "First Pass has no exam bank yet, so it uses its practice questions.")
    }
}
