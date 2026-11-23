import Foundation
import Testing

@testable import QBankKit

/// Exams on the phone: the plan, the pools, start and replace, the clock, finish and the result.
/// Each rule is the server's; the recordings prove them whole (`LocalBankParityTests`), and these
/// tests hold the corners the recordings do not reach. Invented data only.
@Suite struct LocalBankExamTests {
    // MARK: The plan

    private func draws(_ sizes: [Int]) -> [Int] {
        ExamPlanner.plan(sizes.enumerated().map { ExamPlanner.Pool(label: "f\($0.offset)", questionCount: $0.element) }).draws.map(\.drawn)
    }

    @Test func anExamOfFewerThanFortyQuestionsTakesThemAllAtNinetySecondsEach() {
        let plan = ExamPlanner.plan([ExamPlanner.Pool(label: "a", questionCount: 12), ExamPlanner.Pool(label: "b", questionCount: 8)])
        #expect(plan.questionCount == 20 && plan.timeLimitSeconds == 1800 && plan.draws.map(\.drawn) == [12, 8])
        #expect(ExamPlanner.plan([ExamPlanner.Pool(label: "a", questionCount: 40)]).timeLimitSeconds == 3600)
        #expect(ExamPlanner.plan([]).questionCount == 0)
    }

    @Test func aLargerPoolIsSplitInProportionByLargestRemainderInAnHour() {
        let plan = ExamPlanner.plan([22, 27, 37].map { ExamPlanner.Pool(label: "w", questionCount: $0) })
        #expect(plan.draws.map(\.drawn) == [10, 13, 17] && plan.questionCount == 40 && plan.timeLimitSeconds == 3600)
        #expect(draws([10, 30, 60]) == [4, 12, 24])
    }

    @Test func aSmallFolderBesideLargeOnesStillGivesOneAndTheTotalStaysForty() {
        #expect(draws([1, 100, 100]) == [1, 19, 20])
        // The borrowing folder takes from the first of two equally over their share.
        #expect(draws([100, 1, 100]) == [19, 1, 20])
        #expect(draws([0, 50, 50]) == [0, 20, 20])
        #expect(draws([1, 1, 200]).reduce(0, +) == 40)
    }

    // MARK: Exam setup

    @Test func theSetupListsEveryFolderWithAQuestionAndWhatAnExamDrawsFromIt() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 3)
        try await world.addFolder("Week 2", questions: 2)
        let setup = try await world.setup().body
        #expect(setup["folders"]?.arrayValue?.map { $0["name"]?.stringValue } == ["Week 1", "Week 2"])
        #expect(setup["folders"]?.arrayValue?.map { $0["questionCount"] } == [.number(3), .number(2)] && setup["folders"]?.arrayValue?.first?["source"] == .string("practice"))
        #expect(setup["inProgress"] == .null && setup["exams"] == .array([]) && setup["preview"] == .null && setup["courseExams"] == .array([]))
        #expect(setup["rules"] == .object(["maxQuestions": .number(40), "fullTimeSeconds": .number(3600), "secondsPerQuestion": .number(90)]))
        let weeks = try #require(setup["weeks"]?.arrayValue)
        #expect(weeks.map { $0["label"]?.stringValue } == ["Week 1", "Week 2"])
    }

    @Test func theSetupPreviewsTheExamTheTickedFoldersWouldGiveFromRepeatedQueryNames() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 3)
        try await world.addFolder("Week 2", questions: 2)
        let one = try #require(world.folders["Week 1"])
        let two = try #require(world.folders["Week 2"])
        let preview = try #require(try await world.setup("?folderIds=\(two)&folderIds=\(one)").body["preview"])
        // Folders come in the course's order, whatever order they were ticked in.
        #expect(preview["folders"]?.arrayValue?.map { $0["name"]?.stringValue } == ["Week 1", "Week 2"])
        #expect(preview["questionCount"] == .number(5) && preview["timeLimitSeconds"] == .number(450) && preview["practiceWeeks"] == .null)
        // A folder that is not in the course is left out, not refused: only starting refuses it.
        let missing = try await world.setup("?folderIds=00000000-0000-4000-8000-0000000000aa").body["preview"]
        #expect(missing?["folders"] == .array([]) && missing?["questionCount"] == .number(0))
        // Legacy weeks name every folder of that name.
        #expect(try await world.setup("?weeks=Week%202").body["preview"]?["questionCount"] == .number(2))
        #expect(try await world.setup("?folderIds=\(one)&pool=wrong").body["preview"]?["questionCount"] == .number(0))
    }

    @Test func aSetupAskForFoldersAndWeeksTogetherOrABadQueryIsRefused() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let one = try #require(world.folders["Week 1"])
        #expect(words(try await world.setup("?folderIds=\(one)&weeks=Week%201")) == "400 folders_and_weeks Send folderIds or weeks, not both.")
        #expect(try await world.setup("?pool=some").status == 400)
        #expect(try await world.setup("?folderIds=nope").body["error"] == .string("invalid_request"))
        #expect(words(try await world.harness.send("GET", "/api/courses/00000000-0000-4000-8000-0000000000aa/exams")) == "404 course_not_found That course is not in the app.")
        #expect(try await world.harness.send("GET", "/api/courses/nope/exams").body["error"] == .string("invalid_request"))
    }

    // MARK: The pools

    @Test func aFolderWithAnExamBankDrawsOnlyItsExamQuestionsAndNamesTheFoldersWithout() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 3)
        try await world.addFolder("Week 1", questions: 2, kind: "exam")
        try await world.addFolder("Week 2", questions: 4)
        let setup = try await world.setup().body
        let folders = try #require(setup["folders"]?.arrayValue)
        #expect(folders.map { $0["source"]?.stringValue } == ["exam", "practice"] && folders.map { $0["questionCount"] } == [.number(2), .number(4)])
        let exam = try await world.start(["Week 1", "Week 2"]).body
        #expect(exam["practiceWeeks"] == .array([.string("Week 2")]) && exam["questions"]?.arrayValue?.count == 6)
        let names = try #require(exam["questions"]?.arrayValue).compactMap { $0["publicId"]?.stringValue }
        #expect(Set(names).isSuperset(of: ["Week 1-1", "Week 1-2"]) && names.count == 6)
        // The exam-bank questions are only asked on exams: nothing of the practice set is drawn from Week 1.
        #expect(try #require(exam["questions"]?.arrayValue).allSatisfy { $0["type"]?.stringValue == "single" })
    }

    @Test func aWrongQuestionsExamDrawsWhatWasLastAnsweredNotFullyRightAndRefusesAFolderWithNone() async throws {
        var world = try await ExamWorld.make()
        let week1 = try await world.addFolder("Week 1", questions: 3)
        try await world.addFolder("Week 2", questions: 2)
        // Week 1: the first question right, the second wrong, the third partly answered wrong then right.
        try await world.answer(week1[0], choice: 0)
        try await world.answer(week1[1], choice: 0)
        try await world.answer(week1[2], choice: 0)
        world.at(5)
        try await world.answer(week1[2], choice: 2)
        let setup = try await world.setup().body["folders"]?.arrayValue
        #expect(setup?.map { $0["wrongCount"] } == [.number(1), .number(0)])
        let refused = try await world.start(["Week 1", "Week 2"], pool: "wrong")
        #expect(words(refused) == "400 no_wrong_questions Week 2 has no wrong questions. Untick it, or turn off Wrong questions only.")
        let exam = try await world.start(["Week 1"], pool: "wrong").body
        #expect(exam["pool"] == .string("wrong") && exam["questions"]?.arrayValue?.map { $0["id"]?.stringValue } == [week1[1]])
        #expect(exam["timeLimitSeconds"] == .number(90))
    }

    @Test func anExamQuestionIsWrongWhileItsPracticeTwinIsUntilItIsAnsweredFullyRightAfterwards() async throws {
        var world = try await ExamWorld.make()
        let practice = try await world.addFolder("Week 1", questions: 2)
        let bank = try await world.addFolder("Week 1", questions: 2, kind: "exam", twins: ["Week 1-1", "Week 1-2"])
        #expect(try await world.setup().body["folders"]?.arrayValue?.first?["wrongCount"] == .number(0))
        // Her practice answer to the first question is wrong, so its twin is wrong until it is answered right after.
        world.at(10)
        try await world.answer(practice[0], choice: 1)
        #expect(try await world.setup().body["folders"]?.arrayValue?.first?["wrongCount"] == .number(1))
        let exam = try await world.start(["Week 1"], pool: "wrong").body
        let id = try #require(exam["id"]?.stringValue)
        #expect(exam["questions"]?.arrayValue?.map { $0["id"]?.stringValue } == [bank[0]])
        world.at(20)
        try await world.answer(bank[0], choice: 0, exam: id)
        _ = try await world.finish(id)
        #expect(try await world.setup().body["folders"]?.arrayValue?.first?["wrongCount"] == .number(0))
        // Answering the practice question wrong again makes the twin wrong again.
        world.at(30)
        try await world.answer(practice[0], choice: 2)
        #expect(try await world.setup().body["folders"]?.arrayValue?.first?["wrongCount"] == .number(1))
    }

    @Test func aQuestionOfAFolderThatHasNoneHasNoPoolAndAFolderMustHoldQuestionsToBeStartedOver() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let empty = try await world.harness.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("Empty")]))
        let emptyID = try #require(empty.body["id"]?.stringValue)
        #expect(try await world.setup().body["folders"]?.arrayValue?.count == 1)
        #expect(words(try await world.start([emptyID])) == "400 folder_empty Empty has no questions.")
        #expect(words(try await world.start(["00000000-0000-4000-8000-0000000000aa"])) == "400 folder_not_found That folder is not in this course.")
        #expect(words(try await world.start([])) == "400 no_folders Tick at least one folder.")
        #expect(words(try await world.start(["Week 1"], extra: ["weeks": .array([.string("Week 1")])])) == "400 folders_and_weeks Send folderIds or weeks, not both.")
        let legacy = try await world.harness.send("POST", "/api/courses/\(world.course)/exams", .object(["weeks": .array([.string("Week 9")])]))
        #expect(words(legacy) == "400 week_not_found Week 9 has no questions in this course.")
        #expect(words(try await world.harness.send("POST", "/api/courses/\(world.course)/exams", .object(["weeks": .array([.string("  ")])]))) == "400 no_weeks Tick at least one week.")
        #expect(try await world.start(["Week 1"], extra: ["pool": .string("some")]).body["error"] == .string("invalid_request"))
    }

    // MARK: Starting, replacing and the clock

    @Test func startingAnExamDrawsItsQuestionsInTheSameOrderItReadsThemAndTimesItByItsSize() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 3)
        let started = try await world.start(["Week 1"])
        #expect(started.status == 201)
        let exam = started.body
        #expect(exam["status"] == .string("running") && exam["timeLimitSeconds"] == .number(270) && exam["weeks"] == .array([.string("Week 1")]))
        #expect(exam["startedAt"] == .string(world.time(0)) && exam["endsAt"] == .string(world.time(270)) && exam["serverNow"] == .string(world.time(0)))
        #expect(exam["finishedAt"] == .null && exam["endReason"] == .null && exam["result"] == .null && exam["answeredQuestionIds"] == .array([]))
        let questions = try #require(exam["questions"]?.arrayValue)
        #expect(questions.map { $0["position"] } == [.number(1), .number(2), .number(3)] && Set(questions.compactMap { $0["weekLabel"]?.stringValue }) == ["Week 1"])
        let read = try await world.read(try #require(exam["id"]?.stringValue))
        #expect(read.body["questions"] == exam["questions"])
    }

    @Test func anExamOfFortyDrawsEachFolderInProportionFromItsOwnQuestions() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 30)
        try await world.addFolder("Week 2", questions: 50)
        let exam = try await world.start(["Week 1", "Week 2"]).body
        let questions = try #require(exam["questions"]?.arrayValue)
        #expect(questions.count == 40 && exam["timeLimitSeconds"] == .number(3600))
        let byWeek = Dictionary(grouping: questions, by: { $0["weekLabel"]?.stringValue ?? "" }).mapValues(\.count)
        #expect(byWeek == ["Week 1": 15, "Week 2": 25])
        #expect(Set(questions.compactMap { $0["id"]?.stringValue }).count == 40)
    }

    @Test func aRunningExamIsNotEndedUnaskedAndReplacingItNeedsItsId() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let first = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(5)
        let refused = try await world.start(["Week 1"])
        #expect(refused.status == 409 && refused.body["error"] == .string("exam_in_progress"))
        #expect(refused.body["message"] == .string("An exam is still running. Starting a new one ends it, so confirm that first."))
        #expect(refused.body["inProgress"]?["id"]?.stringValue == first && refused.body["inProgress"]?["status"] == .string("running"))
        #expect(try world.count("study_session", "mode = 'exam'") == 1 && world.count("study_session", "finished_at IS NOT NULL") == 0)
        // Another exam's id is not the confirmation.
        #expect(try await world.start(["Week 1"], replaces: .string("00000000-0000-4000-8000-0000000000aa")).status == 409)
        let second = try await world.start(["Week 1"], replaces: .string(first))
        #expect(second.status == 201)
        let left = try await world.read(first).body
        #expect(left["status"] == .string("ended") && left["endReason"] == .string("left") && left["finishedAt"] == .string(world.time(5)))
        #expect(left["result"]?["minutesUsed"] == .number(1))
    }

    @Test func anAppFromBeforeReplacesEndsTheRunningExamUnasked() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let first = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(3)
        #expect(try await world.start(["Week 1"], replaces: nil).status == 201)
        #expect(try await world.read(first).body["endReason"] == .string("left"))
        #expect(try world.count("study_session", "mode = 'exam' AND finished_at IS NULL") == 1)
    }

    @Test func anExamInItsGraceStillCountsAsRunningAndEndsAsATimeoutAtItsEnd() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let first = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(270)
        #expect(try await world.read(first).body["status"] == .string("grace"))
        world.at(300)
        #expect(try await world.read(first).body["status"] == .string("grace"))
        let setup = try await world.setup().body
        #expect(setup["inProgress"]?["id"]?.stringValue == first && setup["inProgress"]?["status"] == .string("grace") && setup["exams"] == .array([]))
        let refused = try await world.start(["Week 1"], replaces: .null)
        #expect(refused.status == 409 && refused.body["inProgress"]?["status"] == .string("grace"))
        #expect(try await world.start(["Week 1"], replaces: .string(first)).status == 201)
        let ended = try await world.read(first).body
        #expect(ended["endReason"] == .string("timeout") && ended["finishedAt"] == .string(world.time(270)) && ended["status"] == .string("ended"))
    }

    @Test func anExamWhoseTimeIsUpReadsAsEndedASettledTimeoutAndIsNotReplacedByConfirming() async throws {
        var world = try await ExamWorld.make()
        let questions = try await world.addFolder("Week 1")
        let exam = try await world.start(["Week 1"]).body
        let first = try #require(exam["id"]?.stringValue)
        try await world.answer(try world.question(exam, "Week 1-1"), choice: 0, exam: first)
        world.at(270 + 30.001)
        // Past the grace nothing is open: the next read records the end, as a timeout at its end time.
        #expect(try world.count("study_session", "finished_at IS NULL") == 1)
        let setup = try await world.setup().body
        #expect(setup["inProgress"] == .null && setup["exams"]?.arrayValue?.count == 1)
        let summary = try #require(setup["exams"]?.arrayValue?.first)
        #expect(summary["status"] == .string("ended") && summary["endReason"] == .string("timeout") && summary["finishedAt"] == .string(world.time(270)))
        #expect(summary["answeredCount"] == .number(1) && summary["fullyRight"] == .number(1) && summary["maxPoints"] == .number(3))
        #expect(try world.count("study_session", "finished_at IS NOT NULL") == 1)
        #expect(questions.count == 3)
        // An exam whose time is up never needs replacing.
        #expect(try await world.start(["Week 1"], replaces: .null).status == 201)
    }

    @Test func anAnswerIsTakenInTheGraceAndRefusedOnceTheTimeIsUp() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let exam = try await world.start(["Week 1"]).body
        let id = try #require(exam["id"]?.stringValue)
        world.at(280)
        #expect(try await world.answer(try world.question(exam, "Week 1-1"), choice: 0, exam: id).status == 201)
        world.at(301)
        #expect(words(try await world.answer(try world.question(exam, "Week 1-2"), choice: 1, exam: id)) == "409 exam_finished This exam has ended. That answer was not saved.")
        #expect(try await world.read(id).body["answeredQuestionIds"]?.arrayValue?.count == 1)
    }

    // MARK: Finishing and the result

    @Test func finishingScoresWhatWasAnsweredAndTheResultCountsEveryQuestion() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 4)
        try await world.addFolder("Week 2", questions: 2)
        let exam = try await world.start(["Week 1", "Week 2"]).body
        let id = try #require(exam["id"]?.stringValue)
        world.at(60)
        try await world.answer(try world.question(exam, "Week 1-1"), choice: 0, exam: id)
        try await world.answer(try world.question(exam, "Week 1-2"), choice: 0, exam: id)
        try await world.answer(try world.question(exam, "Week 2-1"), choice: 0, exam: id, guessed: true)
        let midway = try await world.read(id).body
        #expect(midway["result"] == .null && midway["answeredQuestionIds"]?.arrayValue?.count == 3)
        world.at(150)
        let done = try await world.finish(id)
        #expect(done.status == 200 && done.body["status"] == .string("ended") && done.body["endReason"] == .string("finished") && done.body["finishedAt"] == .string(world.time(150)))
        let result = try #require(done.body["result"])
        #expect(result["questionCount"] == .number(6) && result["answered"] == .number(3) && result["unanswered"] == .number(3))
        #expect(result["fullyRight"] == .number(2) && result["missed"] == .number(1) && result["partial"] == .number(0) && result["guessed"] == .number(1))
        #expect(result["points"] == .number(2) && result["maxPoints"] == .number(6) && result["minutesUsed"] == .number(3))
        // The wrong answer and the guess go to Review; skipped and unreached questions stay out.
        #expect(result["reviewCount"] == .number(2) && result["examBankWrong"] == .number(0))
        let byFolder = try #require(result["byFolder"]?.arrayValue)
        #expect(byFolder.map { $0["label"]?.stringValue } == ["Week 1", "Week 2"] && byFolder.map { $0["right"] } == [.number(1), .number(1)] && byFolder.map { $0["total"] } == [.number(4), .number(2)])
        #expect(result["byStep"]?.arrayValue?.map { $0["label"]?.stringValue } == ["Not labeled"] && result["byWeek"]?.arrayValue?.count == 2)
        let items = try #require(result["items"]?.arrayValue)
        #expect(items.count == 6 && items.filter { $0["status"] == .string("unanswered") }.allSatisfy { $0["label"] == .string("Not answered") && $0["points"] == .number(0) && $0["response"] == .null })
        let answered = try #require(items.first { $0["questionId"]?.stringValue == (try? world.question(exam, "Week 2-1")) })
        #expect(answered["guessed"] == .bool(true) && answered["response"]?["choice"] == .number(0) && answered["label"] == .string("Correct"))
    }

    @Test func finishingAnEndedExamReturnsItUnchangedAndAnExamPastItsTimeEndsAsATimeout() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let id = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(100)
        let first = try await world.finish(id, "left")
        world.at(200)
        let again = try await world.finish(id, "finished")
        // Only what the clock says differs: the exam itself is as it was ended.
        #expect(again.body["endReason"] == .string("left") && again.body["finishedAt"] == first.body["finishedAt"] && again.body["result"] == first.body["result"])
        #expect(again.body["serverNow"] == .string(world.time(200)) && first.body["serverNow"] == .string(world.time(100)))
        let late = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        world.at(200 + 1000)
        let ended = try await world.finish(late, "finished")
        #expect(ended.body["endReason"] == .string("timeout") && ended.body["finishedAt"] == .string(world.time(200 + 270)))
        #expect(words(try await world.finish("00000000-0000-4000-8000-0000000000aa")) == "404 exam_not_found That exam is not in the app.")
        #expect(try await world.harness.send("POST", "/api/exams/\(id)/finish", .object(["reason": .string("quit")])).body["error"] == .string("invalid_request"))
    }

    @Test func anExamBankQuestionStaysOutOfReviewAndIsCountedAsExamBankWrong() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 2)
        let bank = try await world.addFolder("Week 1", questions: 2, kind: "exam")
        let exam = try await world.start(["Week 1"]).body
        let id = try #require(exam["id"]?.stringValue)
        try await world.answer(bank[0], choice: 1, exam: id)
        try await world.answer(bank[1], choice: 1, exam: id)
        let result = try #require(try await world.finish(id).body["result"])
        #expect(result["reviewCount"] == .number(0) && result["examBankWrong"] == .number(1) && result["fullyRight"] == .number(1))
        #expect(try world.count("question_progress", "in_review = 1") == 0)
        #expect(try await world.setup().body["folders"]?.arrayValue?.first?["wrongCount"] == .number(1))
    }

    @Test func theResultGroupsByStepInTheOrderOfTheClinicalJudgmentSteps() async throws {
        let world = try await ExamWorld.make()
        let file = Files.make(
            "Steps",
            [
                Files.single("A", extra: ["cj": .string("Take action")]), Files.single("B", extra: ["cj": .string("recognize cues")]),
                Files.single("C", extra: ["cj": .string("Evaluate outcomes")]), Files.single("D"),
            ])
        _ = try await world.harness.importFile(file, into: world.course, folderName: "Week 1")
        let id = try #require(try await world.start(["\(try await folderID(world, "Week 1"))"]).body["id"]?.stringValue)
        let result = try #require(try await world.finish(id).body["result"])
        #expect(result["byStep"]?.arrayValue?.map { $0["label"]?.stringValue } == ["recognize cues", "Take action", "Evaluate outcomes", "Not labeled"])
    }

    private func folderID(_ world: ExamWorld, _ name: String) async throws -> String {
        let course = try await world.harness.send("GET", "/api/courses/\(world.course)")
        return try #require(course.body["folders"]?.arrayValue?.first { $0["name"]?.stringValue == name }?["id"]?.stringValue)
    }

    // MARK: Past exams and a folder renamed since

    @Test func aPastExamKeepsTheNamesItWasOverAndLosesAFolderRemovedSince() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let empty = try await world.harness.send("POST", "/api/courses/\(world.course)/folders", .object(["name": .string("Spare")]))
        #expect(empty.status == 201)
        let id = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        _ = try await world.finish(id)
        _ = try await world.harness.send("PATCH", "/api/folders/\(try #require(world.folders["Week 1"]))", .object(["name": .string("Renamed")]))
        let exam = try await world.read(id).body
        let folder = try #require(world.folders["Week 1"])
        #expect(exam["weeks"] == .array([.string("Week 1")]) && exam["folderIds"] == .array([.string(folder)]))
        let byFolder = try #require(exam["result"]?["byFolder"]?.arrayValue)
        #expect(byFolder.map { $0["label"]?.stringValue } == ["Renamed"])
    }

    @Test func anExamBelongsToThePageThatHoldsEveryFolderItWasOver() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        try await world.addFolder("Week 2")
        let page = try await world.harness.send(
            "POST", "/api/courses/\(world.course)/course-exams",
            .object(["name": .string("Midterm"), "folderIds": .array([.string(try #require(world.folders["Week 1"])), .string(try #require(world.folders["Week 2"]))])]))
        let pageID = try #require(page.body["id"]?.stringValue)
        let both = try #require(try await world.start(["Week 1", "Week 2"]).body["id"]?.stringValue)
        _ = try await world.finish(both)
        let one = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        _ = try await world.finish(one)
        let setup = try await world.setup().body
        #expect(setup["exams"]?.arrayValue?.map { $0["courseExamId"] } == [.string(pageID), .string(pageID)])
        #expect(setup["courseExams"]?.arrayValue?.first?["courseExamId"] == .string(pageID))
        #expect(setup["courseExams"]?.arrayValue?.first?["preview"]?["questionCount"] == .number(6))
        #expect(setup["folders"]?.arrayValue?.map { $0["examPageId"] } == [.string(pageID), .string(pageID)])
    }

    @Test func anExamOfACourseThatWasDeletedIsNotInTheApp() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1")
        let id = try #require(try await world.start(["Week 1"]).body["id"]?.stringValue)
        _ = try await world.finish(id)
        try world.harness.store.run("UPDATE course SET deleted_at = ?, deletion_id = ? WHERE id = ?", [.text(world.time(1)), .text("dd000000-0000-4000-8000-000000000001"), .text(world.course)])
        #expect(words(try await world.read(id)) == "404 exam_not_found That exam is not in the app.")
        #expect(words(try await world.setup()) == "404 course_not_found That course is not in the app.")
        #expect(words(try await world.start(["Week 1"])) == "404 course_not_found That course is not in the app.")
    }

    @Test func theCourseCardReadsTheTimeAnExamOverEveryFolderGets() async throws {
        var world = try await ExamWorld.make()
        try await world.addFolder("Week 1", questions: 3)
        let course = try await world.harness.send("GET", "/api/courses/\(world.course)")
        #expect(course.body["examTimeLimitSeconds"] == .number(270) && course.body["examQuestionCount"] == .number(3))
    }
}
