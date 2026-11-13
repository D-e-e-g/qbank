import Foundation
import QBankKit
import Testing
@testable import QBank

/// The fake server's study rules that the UI tests lean on, read straight from `FakeStudy`: exam
/// starts, answers and results, her past exams, folders and exam pages, and where an import files
/// its sets. Each answer is the one the server gives, in its words.
struct FakeStudyRulesTests {
    static let course = FakeQBankServer.mentalHealthID
    static let fundamentalsWeek1 = "f0000000-0000-4000-8000-000000002201"

    /// A folder as a reply draws it, enough to read back.
    static func folderJSON(_ folder: FakeStudy.Folder) -> [String: Any] {
        ["id": folder.id, "name": folder.name, "examPageId": folder.examPageID ?? NSNull(), "sortOrder": folder.sortOrder, "sets": folder.sets]
    }

    static func call(_ study: FakeStudy, _ method: String, _ path: String, query: [String: String] = [:], body: [String: Any] = [:]) throws -> FakeStudy.Reply {
        try #require(study.answer(method: method, path: path, query: query, body: body, folderJSON: folderJSON))
    }

    static func refusal(_ reply: FakeStudy.Reply) -> String {
        "\(reply.0) \(reply.1["error"] as? String ?? "-"): \(reply.1["message"] as? String ?? "-")"
    }

    static func start(_ study: FakeStudy, _ folderIDs: [String], pool: String = "all") throws -> FakeStudy.Reply {
        try call(study, "POST", "/api/courses/\(course)/exams", body: ["folderIds": folderIDs, "pool": pool])
    }

    static func newFolder(_ study: FakeStudy, _ name: String, page: String? = nil) throws -> String {
        let made = try call(study, "POST", "/api/courses/\(course)/folders", body: page.map { ["name": name, "examPageId": $0] } ?? ["name": name])
        #expect(made.0 == 201)
        return try #require(made.1["id"] as? String)
    }

    static func answer(_ study: FakeStudy, exam: String, _ questionID: String, _ make: (QuestionBody) -> AnswerResponse?, guessed: Bool = false) throws -> FakeStudy.Reply {
        let body = try #require(FakeStudy.question(questionID)?.body)
        let response = try #require(make(body))
        return study.examAnswer(sessionID: exam, clientAttemptID: "test-\(questionID)", questionID: questionID, response: response, guessed: guessed, shuffle: nil)
    }

    /// Rows of a result's breakdown, as "label right/total".
    static func rows(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).map { "\($0["label"] as? String ?? "") \($0["right"] as? Int ?? -1)/\($0["total"] as? Int ?? -1)" }
    }

    // MARK: Exams

    @Test func aStartIsRefusedInTheServersWords() throws {
        let study = FakeStudy(now: .now)
        #expect(try Self.refusal(Self.start(study, [])) == "400 no_folders: Tick at least one folder.")
        #expect(try Self.refusal(Self.start(study, ["f-unknown"])) == "400 folder_not_found: That folder is not in this course.")
        #expect(try Self.refusal(Self.start(study, [Self.fundamentalsWeek1])) == "400 folder_not_found: That folder is not in this course.")
        let emptyA = try Self.newFolder(study, "Empty A")
        let emptyB = try Self.newFolder(study, "Empty B")
        #expect(try Self.refusal(Self.start(study, [emptyA])) == "400 no_questions: Empty A has no questions.")
        #expect(try Self.refusal(Self.start(study, [emptyB, emptyA])) == "400 no_questions: Empty A and Empty B have no questions.")
        #expect(
            try Self.refusal(Self.start(study, [emptyA, FakeStudy.week3], pool: "wrong"))
                == "400 no_wrong_questions: Week 3 and Empty A have no wrong questions. Untick them, or turn off Wrong questions only."
        )
        #expect(try Self.call(study, "GET", "/api/courses/\(Self.course)/exams").1["inProgress"] is NSNull, "nothing started")
    }

    @Test func anExamIsServedInOrderAndEachAnswerIsSavedOnce() throws {
        let study = FakeStudy(now: .now)
        let started = try Self.start(study, [FakeStudy.weeks1to3])
        #expect(started.0 == 201)
        let id = try #require(started.1["id"] as? String)
        #expect(id == "e0000000-0000-4000-8000-000000000004", "after her three past exams")
        let questions = try #require(started.1["questions"] as? [[String: Any]])
        let ids = questions.compactMap { $0["id"] as? String }
        #expect(ids == FakeStudy.ids("mixed-v1", 8))
        #expect(questions.map { $0["position"] as? Int } == Array(1...8))
        #expect(questions.map { $0["publicId"] as? String } == (1...8).map { "Q\($0)" })
        #expect(questions.allSatisfy { $0["weekLabel"] as? String == "Weeks 1-3" })
        #expect(started.1["courseCode"] as? String == "NURS 310")
        #expect(started.1["courseTitle"] as? String == "Mental Health")
        #expect(started.1["weeks"] as? [String] == ["Weeks 1-3"])
        #expect(started.1["timeLimitSeconds"] as? Int == 720)
        #expect(started.1["practiceWeeks"] as? [String] == ["Weeks 1-3"], "her course has exam banks, and this folder has none")
        #expect(started.1["finishedAt"] is NSNull)
        #expect(started.1["result"] is NSNull)
        #expect(started.1["answeredQuestionIds"] as? [String] == [])

        let right = try Self.answer(study, exam: id, ids[0], FakeAnswers.right)
        #expect(right.0 == 201)
        #expect(right.1["status"] as? String == "correct")
        #expect(right.1["label"] as? String == "Correct")
        #expect(right.1["inReview"] as? Bool == false)
        #expect(right.1["replayed"] as? Bool == false)
        #expect(right.1["courseId"] as? String == Self.course)
        #expect(right.1["clientAttemptId"] as? String == "test-\(ids[0])")
        let wrong = try Self.answer(study, exam: id, ids[1], FakeAnswers.wrong)
        #expect(wrong.1["status"] as? String == "incorrect")
        #expect(wrong.1["inReview"] as? Bool == true)
        let review = try Self.call(study, "GET", "/api/courses/\(Self.course)/review")
        let top = try #require((review.1["questions"] as? [[String: Any]])?.first)
        #expect(top["questionId"] as? String == ids[1])
        #expect(top["setTitle"] as? String == "Exam")
        #expect(top["weekLabel"] as? String == "Weeks 1-3")

        #expect(try Self.refusal(Self.answer(study, exam: id, ids[0], FakeAnswers.wrong)) == "409 already_answered: That question was already answered on this exam.")
        #expect(try Self.refusal(Self.answer(study, exam: id, "rights-v1-q0", FakeAnswers.right)) == "400 question_not_in_exam: That question is not on this exam.")
        #expect(try Self.refusal(Self.answer(study, exam: "e-unknown", ids[2], FakeAnswers.right)) == "404 exam_not_found: That exam is not in the app.")
        let mismatched = study.examAnswer(sessionID: id, clientAttemptID: "x", questionID: ids[2], response: .single(choice: 0), guessed: false, shuffle: nil)
        #expect(mismatched.0 == 400)
        #expect(mismatched.1["error"] as? String == "invalid_request")
        #expect(!(mismatched.1["message"] as? String ?? "").isEmpty)
        #expect(try Self.call(study, "GET", "/api/exams/\(id)").1["answeredQuestionIds"] as? [String] == Array(ids.prefix(2)))

        let ended = try Self.call(study, "POST", "/api/exams/\(id)/finish", body: ["reason": "left"])
        #expect(ended.0 == 200)
        #expect(ended.1["endReason"] as? String == "left")
        #expect(try Self.refusal(Self.answer(study, exam: id, ids[2], FakeAnswers.right)) == "409 exam_finished: This exam has ended. That answer was not saved.")
        #expect(try Self.refusal(Self.call(study, "GET", "/api/exams/e-unknown")) == "404 exam_not_found: That exam is not in the app.")
        #expect(try Self.refusal(Self.call(study, "POST", "/api/exams/e-unknown/finish")) == "404 exam_not_found: That exam is not in the app.")
    }

    @Test func anEndedExamIsCountedByFolderStepAndQuestion() throws {
        let study = FakeStudy(now: .now)
        let id = try #require(try Self.start(study, [FakeStudy.weeks1to3]).1["id"] as? String)
        let ids = FakeStudy.ids("mixed-v1", 8)
        _ = try Self.answer(study, exam: id, ids[0], FakeAnswers.right)
        _ = try Self.answer(study, exam: id, ids[1], FakeAnswers.wrong)
        _ = try Self.answer(study, exam: id, ids[2], FakeAnswers.partly)
        _ = try Self.answer(study, exam: id, ids[3], FakeAnswers.right, guessed: true)
        _ = try Self.call(study, "POST", "/api/exams/\(id)/finish", body: ["reason": "finished"])
        // The folder is renamed after: by folder says its name now, by week the one it had.
        _ = try Self.call(study, "PATCH", "/api/folders/\(FakeStudy.weeks1to3)", body: ["name": "Mixed"])

        let exam = try Self.call(study, "GET", "/api/exams/\(id)")
        #expect(exam.1["endReason"] as? String == "finished")
        let result = try #require(exam.1["result"] as? [String: Any])
        #expect(result["questionCount"] as? Int == 8)
        #expect(result["answered"] as? Int == 4)
        #expect(result["unanswered"] as? Int == 4)
        #expect(result["fullyRight"] as? Int == 2)
        #expect(result["partial"] as? Int == 1)
        #expect(result["missed"] as? Int == 1)
        #expect(result["guessed"] as? Int == 1)
        #expect(result["points"] as? Int == 6)
        #expect(result["maxPoints"] as? Int == 22)
        #expect(result["minutesUsed"] as? Int == 1)
        #expect(result["reviewCount"] as? Int == 3, "the wrong, the partly right and the guessed one")
        #expect(result["examBankWrong"] as? Int == 0)
        #expect(Self.rows(result["byWeek"]) == ["Weeks 1-3 2/8"])
        #expect(Self.rows(result["byFolder"]) == ["Mixed 2/8"])
        #expect((result["byFolder"] as? [[String: Any]])?.first?["folderId"] as? String == FakeStudy.weeks1to3)
        #expect(
            Self.rows(result["byStep"])
                == ["Recognize cues 1/1", "Analyze cues 0/1", "Prioritize hypotheses 0/1", "Generate solutions 0/2", "Take action 1/2", "Evaluate outcomes 0/1"],
            "in the order of the steps"
        )
        let items = try #require(result["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["questionId"] as? String } == ids)
        #expect(items.compactMap { $0["status"] as? String } == ["correct", "incorrect", "partial", "correct"] + Array(repeating: "unanswered", count: 4))
        #expect(items.compactMap { $0["label"] as? String } == ["Correct", "Not correct", "Partly correct", "Correct"] + Array(repeating: "Not answered", count: 4))
        #expect(items.compactMap { $0["points"] as? Int } == [1, 0, 2, 3, 0, 0, 0, 0])
        #expect(items.compactMap { $0["maxPoints"] as? Int } == [1, 1, 3, 3, 4, 4, 3, 3])
        #expect(items.compactMap { $0["guessed"] as? Bool } == [false, false, false, true, false, false, false, false])
        #expect(items.map { $0["response"] is NSNull } == [false, false, false, false, true, true, true, true])
        #expect(items[0]["response"] as? [String: Any] != nil, "the answer she gave, as the app encodes it")

        let setup = try Self.call(study, "GET", "/api/courses/\(Self.course)/exams")
        let summary = try #require((setup.1["exams"] as? [[String: Any]])?.first)
        #expect(summary["id"] as? String == id)
        #expect(summary["courseExamId"] is NSNull, "its folder is on no page")
        #expect(summary["answeredCount"] as? Int == 4)
        #expect(summary["fullyRight"] as? Int == 2)
        #expect(summary["points"] as? Int == result["points"] as? Int)
        #expect(summary["maxPoints"] as? Int == result["maxPoints"] as? Int)
        #expect(summary["minutesUsed"] as? Int == 1)
    }

    /// Her three exams from before this run, answered with each question's own key: right, wrong
    /// and partly right.
    @Test func herPastExamsAreScoredFromTheirAnswers() throws {
        let study = FakeStudy(now: .now)
        let setup = try Self.call(study, "GET", "/api/courses/\(Self.course)/exams")
        let exams = try #require(setup.1["exams"] as? [[String: Any]])
        #expect(exams.compactMap { $0["id"] as? String } == ["e0000000-0000-4000-8000-000000000001", "e0000000-0000-4000-8000-000000000003", "e0000000-0000-4000-8000-000000000002"])
        #expect(exams.compactMap { $0["weeks"] as? [String] } == [["Week 1", "Week 2"], ["Week 1", "Week 2", "Week 3"], ["Week 1"]])
        #expect(exams.compactMap { $0["endReason"] as? String } == ["finished", "finished", "timeout"])
        #expect(exams.compactMap { $0["questionCount"] as? Int } == [40, 40, 17])
        #expect(exams.compactMap { $0["answeredCount"] as? Int } == [40, 40, 15])
        #expect(exams.compactMap { $0["fullyRight"] as? Int } == [32, 30, 13])
        #expect(exams.compactMap { $0["points"] as? Int } == [85, 86, 34])
        #expect(exams.compactMap { $0["maxPoints"] as? Int } == [106, 106, 45])
        #expect(exams.compactMap { $0["minutesUsed"] as? Int } == [52, 41, 26])
        #expect(exams.map { $0["practiceWeeks"] as? [String] } == [["Week 2"], ["Week 2"], []])
        let timedOut = try Self.call(study, "GET", "/api/exams/e0000000-0000-4000-8000-000000000002")
        #expect(timedOut.1["finishedAt"] as? String == timedOut.1["endsAt"] as? String, "time ran out at its end")
        let result = try #require(timedOut.1["result"] as? [String: Any])
        #expect(
            Self.rows(result["byStep"])
                == ["Recognize cues 2/2", "Analyze cues 1/2", "Prioritize hypotheses 2/2", "Generate solutions 3/4", "Take action 4/5", "Evaluate outcomes 1/2"]
        )
    }

    @Test func anExamWhoseTimeRanOutEndsAsATimeoutAtItsEnd() throws {
        let study = FakeStudy(now: .now.addingTimeInterval(-3 * 3600), examInProgress: true)
        let id = "e0000000-0000-4000-8000-000000000004"
        let setup = try Self.call(study, "GET", "/api/courses/\(Self.course)/exams")
        #expect(setup.1["inProgress"] is NSNull)
        #expect((setup.1["exams"] as? [[String: Any]])?.first?["id"] as? String == id)
        let exam = try Self.call(study, "GET", "/api/exams/\(id)")
        #expect(exam.1["endReason"] as? String == "timeout")
        #expect(exam.1["finishedAt"] as? String == exam.1["endsAt"] as? String)
        #expect(try Self.refusal(Self.answer(study, exam: id, "bank1-q0", FakeAnswers.right)) == "409 exam_finished: This exam has ended. That answer was not saved.")
        #expect(try Self.call(study, "POST", "/api/exams/\(id)/finish", body: ["reason": "finished"]).1["endReason"] as? String == "timeout", "an ended exam stays as it ended")
    }

    // MARK: Folders and exam pages

    @Test func foldersAreRefusedInTheServersWords() throws {
        let study = FakeStudy(now: .now)
        let folders = "/api/courses/\(Self.course)/folders"
        #expect(try Self.refusal(Self.call(study, "POST", folders, body: ["name": " "])) == "400 request_refused: Folder name is required.")
        #expect(try Self.refusal(Self.call(study, "POST", folders, body: ["name": String(repeating: "a", count: 81)])) == "400 request_refused: Folder name is too long.")
        #expect(try Self.refusal(Self.call(study, "POST", folders, body: ["name": "New", "examPageId": "c0e-unknown"])) == "400 request_refused: That exam page is not in this course.")
        #expect(try Self.refusal(Self.call(study, "POST", folders, body: ["name": "week 2", "examPageId": FakeStudy.exam1])) == "409 request_refused: Exam 1 already has a folder named Week 2.")
        #expect(
            try Self.refusal(Self.call(study, "POST", "/api/courses/\(FakeQBankServer.fundamentalsID)/folders", body: ["name": "week 1"]))
                == "409 request_refused: NURS 220 already has a folder named Week 1."
        )
        let loose = try Self.call(study, "POST", folders, body: ["name": " Week 1 "])
        #expect(loose.0 == 201, "a name is unique in its own list only")
        #expect(loose.1["name"] as? String == "Week 1")
        #expect(loose.1["examPageId"] is NSNull)
        #expect(loose.1["sortOrder"] as? Int == 2)
        #expect(loose.1["id"] as? String == "f0000000-0000-4000-8000-000000009001")

        #expect(try Self.refusal(Self.call(study, "PATCH", "/api/folders/f-unknown", body: ["name": "X"])) == "404 request_refused: That folder is not in the app.")
        let placed = try Self.call(study, "PATCH", "/api/folders/\(FakeStudy.week3)", body: ["examPageId": FakeStudy.exam1])
        #expect(placed.1["examPageId"] as? String == FakeStudy.exam1)
        #expect(placed.1["sortOrder"] as? Int == 3, "at the end of its new page")
        let off = try Self.call(study, "PATCH", "/api/folders/\(FakeStudy.week3)", body: ["examPageId": NSNull()])
        #expect(off.1["examPageId"] is NSNull)
        #expect(off.1["sortOrder"] as? Int == 3, "at the end of the Folders list")
        #expect(study.folders(Self.course).map(\.name) == ["Week 1", "Week 2", "Weeks 1-3", "Week 1", "Week 3"])

        let move = { (set: String, body: [String: Any]) in try Self.call(study, "POST", "/api/practice-sets/\(set)/move", body: body) }
        #expect(try Self.refusal(move("nope-v1", ["folderId": FakeStudy.week1])) == "404 request_refused: That set is not in the app.")
        #expect(try Self.refusal(move("anxiety-v1", ["folderId": FakeStudy.week1, "newFolderName": "X"])) == "400 request_refused: Choose a folder or a new folder name, not both.")
        #expect(try Self.refusal(move("anxiety-v1", [:])) == "400 request_refused: Choose a folder to move it to.")
        #expect(try Self.refusal(move("anxiety-v1", ["folderId": Self.fundamentalsWeek1])) == "400 request_refused: That folder is not in this course.")
        #expect(try Self.refusal(move("anxiety-v1", ["newFolderName": "  "])) == "400 request_refused: Folder name is required.")
        let stays = try move("anxiety-v1", ["folderId": FakeStudy.week3])
        #expect(stays.1["sets"] as? [String] == ["depression-v1", "anxiety-v1"], "a move to its own folder changes nothing")

        let order = "/api/courses/\(Self.course)/folder-order"
        #expect(try Self.refusal(Self.call(study, "PUT", order, body: ["examPageId": "c0e-unknown", "folderIds": [String]()])) == "400 request_refused: That exam page is not in this course.")
    }

    @Test func examPagesKeepTheirLinkBadgeAndFolders() throws {
        let study = FakeStudy(now: .now)
        let pages = "/api/courses/\(Self.course)/course-exams"
        let made = try Self.call(study, "POST", pages, body: ["name": "Primer", "linkUrl": " https://example.com/primer ", "folderIds": [String]()])
        #expect(made.0 == 201)
        let id = try #require(made.1["id"] as? String)
        #expect(id == "c0e00000-0000-4000-8000-000000000101")
        #expect(made.1["sortOrder"] as? Int == 3)
        #expect(made.1["linkUrl"] as? String == "https://example.com/primer")
        #expect(made.1["badge"] is NSNull)
        let put = { (body: [String: Any]) in try Self.call(study, "PUT", "/api/course-exams/\(id)", body: body) }
        #expect(try put(["name": "Primer"]).1["linkUrl"] as? String == "https://example.com/primer", "left out, the link stays")
        let refusedLink = "400 request_refused: A link has to be a web address, such as https://example.com/primer."
        #expect(try Self.refusal(put(["name": "Primer", "linkUrl": "ftp://example.com/primer"])) == refusedLink)
        #expect(try Self.refusal(put(["name": "Primer", "linkUrl": "https://"])) == refusedLink)
        #expect(try Self.refusal(put(["name": "Primer", "badge": "bogus"])) == "400 invalid_request: That badge is not one QBank knows.")
        #expect(try put(["name": "Primer", "linkUrl": "  "]).1["linkUrl"] is NSNull, "blank takes the link off")
        _ = try put(["name": "Primer", "linkUrl": "http://example.com/a"])
        #expect(try put(["name": "Primer", "linkUrl": NSNull()]).1["linkUrl"] is NSNull, "null takes the link off")
        #expect(try put(["name": "Primer", "badge": "study"]).1["badge"] as? String == "study")

        #expect(try Self.refusal(Self.call(study, "PUT", "/api/course-exams/c0e-unknown", body: ["name": "X"])) == "404 request_refused: That exam is not in the app.")
        #expect(try Self.refusal(Self.call(study, "POST", pages, body: ["name": "X", "folderIds": ["f-unknown"]])) == "400 request_refused: That folder is not in this course.")
        #expect(
            try Self.refusal(Self.call(study, "POST", pages, body: ["name": "X", "folderIds": ["f-unknown", Self.fundamentalsWeek1]]))
                == "400 request_refused: Those folders are not in this course."
        )
        _ = try Self.call(study, "PATCH", "/api/folders/\(FakeStudy.weeks1to3)", body: ["name": "Week 1"])
        #expect(
            try Self.refusal(put(["name": "Primer", "folderIds": [FakeStudy.weeks1to3, FakeStudy.week1]]))
                == "409 request_refused: Week 1 is in Exam 1."
        )
        #expect(
            try Self.refusal(Self.call(study, "PUT", "/api/course-exams/\(FakeStudy.exam1)", body: ["name": "Exam 1", "folderIds": [FakeStudy.week1, FakeStudy.weeks1to3]]))
                == "409 request_refused: Exam 1 already has a folder named Week 1."
        )
        let renamed = try Self.call(study, "PUT", "/api/course-exams/\(FakeStudy.exam1)", body: ["name": "Exam One"])
        #expect(renamed.1["name"] as? String == "Exam One")
        #expect(renamed.1["folderIds"] as? [String] == [FakeStudy.week1, FakeStudy.week2], "without folderIds a page keeps its folders")
        #expect(renamed.1["badge"] as? String == "exam")
    }

    // MARK: Import

    /// Where an import files a set: the folder she picked, the one she named, a new one, or Unsorted.
    @Test func anImportFilesItsSetWhereTheServerWould() throws {
        let study = FakeStudy(now: .now)
        let folder = { (id: String?, name: String?) throws -> FakeStudy.Folder in try study.importFolder(courseID: Self.course, folderID: id, folderName: name).get() }
        #expect(try folder(FakeStudy.week2, nil).id == FakeStudy.week2)
        guard case .failure(let refused) = study.importFolder(courseID: Self.course, folderID: Self.fundamentalsWeek1, folderName: nil) else {
            Issue.record("a folder of another course was picked")
            return
        }
        #expect(refused.status == 400)
        #expect(refused.message == "That folder is not in this course.")
        #expect(try folder(nil, "weeks 1-3").id == FakeStudy.weeks1to3, "named, ignoring case")
        #expect(try folder(nil, "week 3").id == FakeStudy.week3, "the only folder of that name, on a page")
        let hard = try folder(nil, "Hard ones")
        #expect(hard.id == "f0000000-0000-4000-8000-000000009001")
        #expect(hard.examPageID == nil)
        #expect(hard.sortOrder == 2, "at the end of the Folders list")
        _ = try Self.call(study, "PATCH", "/api/folders/\(FakeStudy.weeks1to3)", body: ["name": "Week 1"])
        #expect(try folder(nil, "week 1").id == FakeStudy.weeks1to3, "of two, the one on no page")
        let unsorted = try folder(nil, nil)
        #expect(unsorted.name == "Unsorted")
        #expect(unsorted.sortOrder == 0, "at the top of the Folders list")
        #expect(try folder(nil, nil).id == unsorted.id, "made once")
        #expect(study.folders(Self.course).filter { $0.examPageID == nil }.map(\.name) == ["Unsorted", "Week 1", "Hard ones"])

        study.file(set: "new-v1", in: hard.id, replacing: nil, questionCount: 5)
        study.file(set: "rights-v2", in: hard.id, replacing: "rights-v1", questionCount: 17)
        study.file(bank: ["bank-exam-v1-q0", "bank-exam-v1-q1"], in: hard.id)
        #expect(study.folder(holding: "new-v1")?.id == hard.id)
        #expect(study.folder(FakeStudy.week1)?.sets == ["rights-v2"], "a new version takes the old one's place")
        #expect(study.folder(hard.id)?.bank == ["bank-exam-v1-q0", "bank-exam-v1-q1"])
        let pools = try Self.call(study, "GET", "/api/courses/\(Self.course)/exams").1["folders"] as? [[String: Any]] ?? []
        #expect(pools.first { $0["id"] as? String == hard.id }?["questionCount"] as? Int == 2, "an exam draws from its bank")
        #expect(pools.first { $0["id"] as? String == hard.id }?["source"] as? String == "exam")
    }
}
