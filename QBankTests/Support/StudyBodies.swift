import Foundation

/// Invented server bodies for the study screens, shaped like the real routes' answers: Review,
/// exams, and courses with folders and exam pages.
enum StudyBodies {
    /// An exam page holding folders, by id.
    typealias Page = (id: String, name: String, folders: [String])

    static func week(_ label: String, sets: [String], bank: Int = 0) -> String {
        #"{"label":"\#(label)","sets":[\#(sets.joined(separator: ","))],"examBankCount":\#(bank)}"#
    }

    static func folder(_ id: String, _ name: String, page: String? = nil, order: Int, sets: [String], bank: Int = 0) -> String {
        #"{"id":"\#(id)","name":"\#(name)","examPageId":\#(page.map { "\"\($0)\"" } ?? "null"),"sortOrder":\#(order),"sets":[\#(sets.joined(separator: ","))],"examBankCount":\#(bank)}"#
    }

    static func set(_ id: String, questions: Int, answered: Int = 0, right: Int = 0) -> String {
        let ids = (0..<questions).map { #""\#(id)-q\#($0)""# }.joined(separator: ",")
        let last = answered == 0 ? "null" : #""2026-10-10T00:00:00.000Z""#
        return #"{"id":"\#(id)","title":"Invented \#(id)","description":"","questionCount":\#(questions),"importedAt":"2026-10-01T00:00:00.000Z","activeSince":"2026-10-01T00:00:00.000Z","status":"imported","canRestore":false,"answeredCount":\#(answered),"fullyRightCount":\#(right),"lastAnsweredAt":\#(last),"questionIds":[\#(ids)]}"#
    }

    static func courseExam(_ id: String, _ name: String, order: Int, weeks: [String], folders: [String]? = nil, link: String? = nil, badge: String?? = nil) -> String {
        let list = { (items: [String]) in items.map { "\"\($0)\"" }.joined(separator: ",") }
        let folderField = folders.map { #","folderIds":[\#(list($0))]"# } ?? ""
        let linkField = link.map { #","linkUrl":"\#($0)""# } ?? ""
        // Left out as a server before badges does; .some(nil) is null, no badge.
        let badgeField = badge.map { $0.map { #","badge":"\#($0)""# } ?? #","badge":null"# } ?? ""
        return #"{"id":"\#(id)","name":"\#(name)","sortOrder":\#(order),"weekLabels":[\#(list(weeks))]\#(folderField)\#(linkField)\#(badgeField)}"#
    }

    /// A study topic, as `GET /api/courses/{id}` answers for one: no semester, no code, a study
    /// page Page 1 holding its first folder, with a primer link, and Unsorted on no page.
    static func topicDetail(id: String = "t1", title: String = "Invented Systems Design", link: String? = "https://notes.example.com/caching") -> String {
        let folders = [
            folder("tf1", "Caching", page: "tp1", order: 1, sets: [set("cache", questions: 3)]),
            folder("tf2", "Unsorted", order: 1, sets: [set("loose", questions: 1)]),
        ]
        let page = courseExam("tp1", "Page 1", order: 1, weeks: ["Caching"], folders: ["tf1"], link: link)
        let weeks = [week("Caching", sets: [set("cache", questions: 3)]), week("Unsorted", sets: [set("loose", questions: 1)])]
        return #"{"id":"\#(id)","kind":"topic","code":"","title":"\#(title)","archivedAt":null,"semester":null,"questionCount":4,"examQuestionCount":4,"weekCount":2,"folderCount":2,"termCount":0,"reviewCount":0,"answeredCount":0,"fullyRightCount":0,"points":0,"maxPoints":0,"weeks":[\#(weeks.joined(separator: ","))],"exams":[\#(page)],"folders":[\#(folders.joined(separator: ","))]}"#
    }

    /// The three folders of `course()`, by id, name, and sets: Week 1 done, Week 2 started, Week 3
    /// not started with an exam bank of 20.
    static let threeFolders: [(id: String, name: String, sets: [String], bank: Int)] = [
        ("f1", "Week 1", [set("w1", questions: 10, answered: 10, right: 8)], 0),
        ("f2", "Week 2", [set("w2a", questions: 6, answered: 2, right: 1), set("w2b", questions: 4)], 0),
        ("f3", "Week 3", [set("w3", questions: 12)], 20),
    ]

    /// A course of `threeFolders`, with `pages` holding some of them, in their order on each page.
    /// Its folders come in the course's order, as the server sends them: each page's folders,
    /// pages in order, then the folders on no page. `badges` gives some pages a badge, or nil for
    /// none, by page id; the others have no badge field, as from a server before badges.
    static func course(id: String = "c1", pages: [Page] = [], badges: [String: String?] = [:]) -> String {
        let pageOf = { (folder: String) in pages.first { $0.folders.contains(folder) } }
        let loose = threeFolders.filter { pageOf($0.id) == nil }.map(\.id)
        let ordered = (pages.flatMap(\.folders) + loose).compactMap { id in threeFolders.first { $0.id == id } }
        let folders = ordered.map { folder in
            let page = pageOf(folder.id)
            let order = (page?.folders ?? loose).firstIndex(of: folder.id).map { $0 + 1 } ?? 1
            return StudyBodies.folder(folder.id, folder.name, page: page?.id, order: order, sets: folder.sets, bank: folder.bank)
        }
        let exams = pages.enumerated().map { index, page in
            courseExam(
                page.id, page.name, order: index + 1, weeks: page.folders.compactMap { id in threeFolders.first { $0.id == id }?.name },
                folders: page.folders, badge: badges[page.id]
            )
        }
        let weeks = threeFolders.map { week($0.name, sets: $0.sets, bank: $0.bank) }
        return #"{"id":"\#(id)","code":"NURS 101","title":"Invented Basics","archivedAt":null,"semester":{"id":"s1","number":1,"name":"Semester 1"},"questionCount":32,"examQuestionCount":40,"weekCount":3,"termCount":4,"reviewCount":2,"answeredCount":12,"fullyRightCount":9,"points":9,"maxPoints":12,"weeks":[\#(weeks.joined(separator: ","))],"exams":[\#(exams.joined(separator: ","))],"folders":[\#(folders.joined(separator: ","))]}"#
    }

    /// The same course as a server from before folders sends it: weeks, and exams by week label, or
    /// with `exams` nil, from before course exams too.
    static func legacyCourse(id: String = "c1", exams: [String]? = []) -> String {
        let weeks = threeFolders.map { week($0.name, sets: $0.sets, bank: $0.bank) }
        let examsField = exams.map { #","exams":[\#($0.joined(separator: ","))]"# } ?? ""
        return #"{"id":"\#(id)","code":"NURS 101","title":"Invented Basics","archivedAt":null,"semester":{"id":"s1","number":1,"name":"Semester 1"},"questionCount":32,"examQuestionCount":40,"weekCount":3,"termCount":4,"reviewCount":2,"answeredCount":12,"fullyRightCount":9,"points":9,"maxPoints":12,"weeks":[\#(weeks.joined(separator: ","))]\#(examsField)}"#
    }

    static func summary(
        _ id: String, weeks: [String], folders: [String]? = nil, courseExam: String? = nil, pool: String = "all",
        finished: Bool = true, reason: String = "finished", answered: Int = 3, questions: Int = 5, right: Int = 2,
        endsAt: String = "2026-10-12T01:00:00.000Z"
    ) -> String {
        let weekList = weeks.map { "\"\($0)\"" }.joined(separator: ",")
        let folderField = folders.map { #""folderIds":[\#($0.map { "\"\($0)\"" }.joined(separator: ","))],"# } ?? ""
        let courseExamField = courseExam.map { "\"\($0)\"" } ?? "null"
        let score = finished ? #""fullyRight":\#(right),"points":\#(right),"maxPoints":\#(questions),"minutesUsed":12"# : #""fullyRight":null,"points":null,"maxPoints":null,"minutesUsed":null"#
        return #"{"id":"\#(id)","courseId":"c1","weeks":[\#(weekList)],\#(folderField)"courseExamId":\#(courseExamField),"pool":"\#(pool)","practiceWeeks":null,"questionCount":\#(questions),"timeLimitSeconds":\#(questions * 90),"startedAt":"2026-10-12T00:00:00.000Z","endsAt":"\#(endsAt)","finishedAt":\#(finished ? #""2026-10-12T00:12:00.000Z""# : "null"),"endReason":\#(finished ? "\"\(reason)\"" : "null"),"answeredCount":\#(answered),\#(score)}"#
    }

    /// A folder's pool in the exam setup.
    typealias Pool = (id: String, name: String, page: String?, count: Int, wrong: Int, source: String)

    /// The server's rules: at most `max` questions in `full` seconds, or `each` seconds a question
    /// when the folders hold fewer.
    typealias Rules = (max: Int, full: Int, each: Int)

    static let rules: Rules = (40, 3600, 90)

    /// `preview` is the server's plan over the folders the setup was read for, and `pages` its plan
    /// for each exam page, by page id.
    static func setup(
        folders: [Pool], inProgress: String? = nil, exams: [String] = [], rules: Rules = rules, preview: String? = nil,
        pages: [(id: String, preview: String)] = []
    ) -> String {
        let weekList = folders.map { #"{"label":"\#($0.name)","questionCount":\#($0.count),"wrongCount":\#($0.wrong),"source":"\#($0.source)"}"# }
        let folderList = folders.map { #"{"id":"\#($0.id)","name":"\#($0.name)","examPageId":\#($0.page.map { "\"\($0)\"" } ?? "null"),"questionCount":\#($0.count),"wrongCount":\#($0.wrong),"source":"\#($0.source)"}"# }
        let ruleField = #""rules":{"maxQuestions":\#(rules.max),"fullTimeSeconds":\#(rules.full),"secondsPerQuestion":\#(rules.each)}"#
        let pageList = pages.map { #"{"courseExamId":"\#($0.id)","preview":\#($0.preview)}"# }
        return #"{"courseId":"c1","weeks":[\#(weekList.joined(separator: ","))],"folders":[\#(folderList.joined(separator: ","))],"inProgress":\#(inProgress ?? "null"),"exams":[\#(exams.joined(separator: ","))],\#(ruleField),"preview":\#(preview ?? "null"),"courseExams":[\#(pageList.joined(separator: ","))]}"#
    }

    /// A folder of the server's plan: the questions it holds in the pool and how many the exam takes.
    typealias Draw = (id: String, name: String, count: Int, drawn: Int, source: String)

    /// The server's plan for an exam over `folders`: its question count and time are the server's,
    /// whatever the folders add up to. `practice` lists the folders without an exam bank, or nil
    /// when the course has none.
    static func preview(_ folders: [Draw], questions: Int? = nil, seconds: Int, practice: [String]? = nil) -> String {
        let rows = folders.map { #"{"id":"\#($0.id)","name":"\#($0.name)","questionCount":\#($0.count),"drawn":\#($0.drawn),"source":"\#($0.source)"}"# }
        let weeks = folders.map { #"{"label":"\#($0.name)","questionCount":\#($0.count),"drawn":\#($0.drawn),"source":"\#($0.source)"}"# }
        let practiceField = practice.map { "[\($0.map { "\"\($0)\"" }.joined(separator: ","))]" } ?? "null"
        return #"{"folders":[\#(rows.joined(separator: ","))],"weeks":[\#(weeks.joined(separator: ","))],"questionCount":\#(questions ?? folders.reduce(0) { $0 + $1.drawn }),"timeLimitSeconds":\#(seconds),"practiceWeeks":\#(practiceField)}"#
    }

    /// The setup of `course()`: Week 3 has an exam bank, and only Weeks 1 and 2 have wrong questions.
    static let threePools: [Pool] = [
        ("f1", "Week 1", nil, 10, 2, "practice"), ("f2", "Week 2", nil, 10, 3, "practice"), ("f3", "Week 3", nil, 20, 0, "exam"),
    ]

    static func question(_ id: String, position: Int, type: String = "single") -> String {
        switch type {
        case "sata":
            return #"{"id":"\#(id)","publicId":"Q\#(position)","position":\#(position),"type":"sata","topic":"Invented \#(id)","cj":"Analyze cues","weekLabel":"Week 1","stem":"Stem.","ask":"Which apply?","rationale":"Because.","takeaway":"Remember.","terms":[],"body":{"options":[{"t":"A","ok":true},{"t":"B"},{"t":"C","ok":true}]}}"#
        default:
            return #"{"id":"\#(id)","publicId":"Q\#(position)","position":\#(position),"type":"single","topic":"Invented \#(id)","cj":"Take action","weekLabel":"Week 1","stem":"Stem.","ask":"Which one?","rationale":"Because.","takeaway":"Remember.","terms":[],"body":{"options":[{"t":"Right","ok":true},{"t":"Wrong"},{"t":"Also wrong"}]}}"#
        }
    }

    /// An exam of `count` single-answer questions, `e1-q0` and on, with 10 minutes left by the
    /// server's clock unless it ended.
    static func exam(
        id: String = "e1", count: Int = 3, answered: [String] = [], ended: String? = nil,
        serverNow: String = "2026-10-12T00:05:00.000Z", endsAt: String = "2026-10-12T00:15:00.000Z", result: String = "null"
    ) -> String {
        let questions = (0..<count).map { question("\(id)-q\($0)", position: $0 + 1) }.joined(separator: ",")
        let answeredList = answered.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":"\#(id)","courseId":"c1","courseCode":"NURS 101","courseTitle":"Invented Basics","weeks":["Week 1","Week 2"],"pool":"wrong","practiceWeeks":null,"timeLimitSeconds":\#(count * 90),"startedAt":"2026-10-12T00:00:00.000Z","endsAt":"\#(endsAt)","finishedAt":\#(ended == nil ? "null" : #""2026-10-12T00:10:00.000Z""#),"endReason":\#(ended.map { "\"\($0)\"" } ?? "null"),"serverNow":"\#(serverNow)","questions":[\#(questions)],"answeredQuestionIds":[\#(answeredList)],"result":\#(result)}"#
    }

    static func result(count: Int = 3) -> String {
        let items = (0..<count).map { #"{"questionId":"e1-q\#($0)","status":"\#($0 == 0 ? "correct" : "unanswered")","points":\#($0 == 0 ? 1 : 0),"maxPoints":1,"guessed":false,"response":\#($0 == 0 ? #"{"type":"single","choice":0}"# : "null"),"shuffle":null}"# }
        return #"{"questionCount":\#(count),"answered":1,"unanswered":\#(count - 1),"fullyRight":1,"partial":0,"missed":0,"guessed":0,"points":1,"maxPoints":\#(count),"minutesUsed":10,"reviewCount":0,"examBankWrong":0,"byWeek":[{"label":"Week 1","right":1,"total":\#(count)}],"byFolder":[{"folderId":"f1","label":"Week 1","right":1,"total":\#(count)}],"byStep":[{"label":"Take action","right":1,"total":\#(count)}],"items":[\#(items.joined(separator: ","))]}"#
    }

    static func saved(question: String, attempt: String, status: String = "correct") -> String {
        #"{"clientAttemptId":"\#(attempt)","questionId":"\#(question)","courseId":"c1","status":"\#(status)","points":1,"maxPoints":1,"guessed":false,"answeredAt":"2026-10-12T00:06:00.000Z","inReview":false,"label":"Correct","replayed":false}"#
    }

    static func review(filter: String = "all", counts: (Int, Int, Int, Int) = (2, 1, 1, 1), questions: [String] = [reviewQuestion("q1", status: "incorrect", guessed: true), reviewQuestion("q2", status: "partial")]) -> String {
        #"{"filter":"\#(filter)","counts":{"all":\#(counts.0),"missed":\#(counts.1),"partial":\#(counts.2),"guessed":\#(counts.3)},"questions":[\#(questions.joined(separator: ","))]}"#
    }

    static func reviewQuestion(_ id: String, status: String, guessed: Bool = false) -> String {
        #"{"questionId":"\#(id)","topic":"Invented \#(id)","weekLabel":"Week 1","format":"Single answer","status":"\#(status)","guessed":\#(guessed),"answeredAt":"2026-10-10T00:00:00.000Z","setTitle":"Invented set"}"#
    }
}
