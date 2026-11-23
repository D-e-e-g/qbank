import Foundation

/// What a course's exams read as: the folders to tick and what an exam over them draws, the person's
/// running exam and past exams, and one exam with its questions and, once it has ended, its result.
enum ExamViews {
    // MARK: What an exam over folders draws

    /// The course's folders in its order, and what an exam over each draws from.
    struct CoursePools {
        let folders: [FolderRow]
        let pools: [String: FolderPool]

        static func load(_ tx: StoreTransaction, courseID: String) throws -> CoursePools {
            let inputs = try StandingRules.inputs(tx, courseID: courseID)
            return CoursePools(folders: try FolderOrder.rows(tx, courseID: courseID), pools: ExamPools.folderPools(inputs.questions, progress: inputs.progress))
        }
    }

    /// What an exam over these folders would draw from each, its time, and the folders that give
    /// practice questions: the plan starting an exam follows. Folders are taken once each, in the
    /// course's order; a folder the course does not have, or that holds no question in the pool, is left out.
    struct Plan {
        let draws: [Draw]
        let plan: ExamPlanner.Plan
        /// The names of the folders without an exam bank, once the course has one; nil before that.
        let practiceWeeks: [String]?
    }

    static func plan(_ course: CoursePools, folderIDs: [String], pool: String) -> Plan {
        let wanted = Set(folderIDs)
        let chosen = course.folders.compactMap { folder -> (folder: FolderRow, pool: FolderPool)? in
            guard wanted.contains(folder.id), let folderPool = course.pools[folder.id], !folderPool.questions(pool).isEmpty else { return nil }
            return (folder, folderPool)
        }
        let plan = ExamPlanner.plan(chosen.map { ExamPlanner.Pool(label: $0.folder.id, questionCount: $0.pool.questions(pool).count) })
        let draws = zip(plan.draws, chosen).map { draw, item in
            Draw(id: item.folder.id, name: item.folder.name, questionCount: draw.questionCount, drawn: draw.drawn, source: item.pool.source)
        }
        // Named only once the course has an exam bank; before that, every exam is practice questions.
        let banked = course.pools.values.contains { $0.source == "exam" }
        return Plan(draws: draws, plan: plan, practiceWeeks: banked ? unique(draws.filter { $0.source == "practice" }.map(\.name)) : nil)
    }

    static func preview(_ course: CoursePools, folderIDs: [String], pool: String) -> JSONValue {
        let plan = plan(course, folderIDs: folderIDs, pool: pool)
        return .object([
            "folders": .array(plan.draws.map(\.json)), "weeks": .array(byName(plan.draws).map(\.weekJSON)), "questionCount": .int(plan.plan.questionCount),
            "timeLimitSeconds": .int(plan.plan.timeLimitSeconds), "practiceWeeks": plan.practiceWeeks.map { .array($0.map(JSONValue.string)) } ?? .null,
        ])
    }

    struct Draw {
        let id: String
        let name: String
        let questionCount: Int
        let drawn: Int
        let source: String

        var json: JSONValue {
            .object(["id": .string(id), "name": .string(name), "questionCount": .int(questionCount), "drawn": .int(drawn), "source": .string(source)])
        }

        var weekJSON: JSONValue {
            .object(["label": .string(name), "questionCount": .int(questionCount), "drawn": .int(drawn), "source": .string(source)])
        }
    }

    /// Legacy rows by folder name, in week order: the folders of one name added up.
    private static func byName(_ draws: [Draw]) -> [Draw] {
        merged(draws, key: \.name) { Draw(id: "", name: $0.name, questionCount: $0.questionCount + $1.questionCount, drawn: $0.drawn + $1.drawn, source: either($0.source, $1.source)) }
    }

    /// A name is `exam` when any of its folders has an exam bank.
    private static func either(_ a: String, _ b: String) -> String { a == "exam" || b == "exam" ? "exam" : "practice" }

    private static func merged<Row>(_ rows: [Row], key: KeyPath<Row, String>, _ merge: (Row, Row) -> Row) -> [Row] {
        var names: [String: Row] = [:]
        var order: [String] = []
        for row in rows {
            let name = row[keyPath: key]
            if let seen = names[name] {
                names[name] = merge(seen, row)
            } else {
                names[name] = row
                order.append(name)
            }
        }
        return order.enumerated().sorted { a, b in
            let byWeek = BankText.compareWeeks(a.element, b.element)
            return byWeek != 0 ? byWeek < 0 : a.offset < b.offset
        }.compactMap { names[$0.element] }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: Exam setup

    /// `GET /api/courses/{id}/exams`.
    static func setup(_ call: BankCall, courseID: String, selection: Selection?) throws -> JSONValue {
        let tx = call.tx
        let course = try CoursePools.load(tx, courseID: courseID)
        let folders = course.folders.compactMap { folder -> (folder: FolderRow, pool: FolderPool)? in
            course.pools[folder.id].map { (folder, $0) }
        }
        let rows = try tx.rows(
            "SELECT * FROM study_session WHERE course_id = ? AND mode = 'exam' AND deleted_at IS NULL ORDER BY started_at DESC, id", [.text(courseID)]
        ).map(ExamRow.init)
        let pages = try PageViews.pages(tx, courseID: courseID)
        let summaries = try summaries(tx, rows, folders: course.folders, pages: pages, now: call.now)
        let weeks = merged(
            folders.map { WeekRow(label: $0.folder.name, questionCount: $0.pool.all.count, wrongCount: $0.pool.wrong.count, source: $0.pool.source) }, key: \.label
        ) { WeekRow(label: $0.label, questionCount: $0.questionCount + $1.questionCount, wrongCount: $0.wrongCount + $1.wrongCount, source: either($0.source, $1.source)) }
        return .object([
            "courseId": .string(courseID), "folders": .array(folders.map(folderJSON)), "weeks": .array(weeks.map(\.json)),
            "inProgress": summaries.first { $0.status != "ended" }?.json ?? .null,
            "exams": .array(summaries.filter { $0.status == "ended" }.map(\.json)),
            "rules": .object([
                "maxQuestions": .int(ExamPlanner.rules.maxQuestions), "fullTimeSeconds": .int(ExamPlanner.rules.fullTimeSeconds),
                "secondsPerQuestion": .int(ExamPlanner.rules.secondsPerQuestion),
            ]),
            "preview": try selection.map { preview(course, folderIDs: try chosenFolders(course, $0, strict: false), pool: $0.pool) } ?? .null,
            "courseExams": .array(
                pages.map { .object(["courseExamId": .string($0.row.id), "preview": preview(course, folderIDs: $0.folders.map(\.id), pool: "all")]) }),
        ])
    }

    private static func folderJSON(_ item: (folder: FolderRow, pool: FolderPool)) -> JSONValue {
        .object([
            "id": .string(item.folder.id), "name": .string(item.folder.name), "examPageId": .optional(item.folder.courseExamId),
            "questionCount": .int(item.pool.all.count), "wrongCount": .int(item.pool.wrong.count), "source": .string(item.pool.source),
        ])
    }

    private struct WeekRow {
        let label: String
        let questionCount: Int
        let wrongCount: Int
        let source: String

        var json: JSONValue {
            .object(["label": .string(label), "questionCount": .int(questionCount), "wrongCount": .int(wrongCount), "source": .string(source)])
        }
    }

    // MARK: The folders a request names

    /// Which folders to start an exam over (or, legacy, which folder names), and from which questions.
    struct Selection {
        var folderIDs: [String]?
        var weeks: [String]?
        var pool: String
    }

    /// The folders a selection names. `folderIds` name them directly; legacy `weeks` name every folder
    /// of each name. With `strict`, as starting an exam is, a folder or name it cannot draw from is refused.
    static func chosenFolders(_ course: CoursePools, _ selection: Selection, strict: Bool) throws -> [String] {
        if selection.folderIDs != nil && selection.weeks != nil { throw BankRefusal.study(400, "folders_and_weeks", "Send folderIds or weeks, not both.") }
        if let weeks = selection.weeks {
            let labels = unique(weeks.map(JS.trim).filter { !$0.isEmpty })
            if strict && labels.isEmpty { throw BankRefusal.study(400, "no_weeks", "Tick at least one week.") }
            if strict {
                for label in labels where !course.folders.contains(where: { $0.name == label && course.pools[$0.id] != nil }) {
                    throw BankRefusal.study(400, "week_not_found", "\(label) has no questions in this course.")
                }
            }
            return course.folders.filter { labels.contains($0.name) && course.pools[$0.id] != nil }.map(\.id)
        }
        let ids = unique(selection.folderIDs ?? [])
        if strict && ids.isEmpty { throw BankRefusal.study(400, "no_folders", "Tick at least one folder.") }
        if strict {
            for id in ids {
                guard let folder = course.folders.first(where: { $0.id == id }) else { throw BankRefusal.study(400, "folder_not_found", "That folder is not in this course.") }
                if course.pools[id] == nil { throw BankRefusal.study(400, "folder_empty", "\(folder.name) has no questions.") }
            }
        }
        return ids
    }

    // MARK: Her exams

    /// A past or running exam as Exam setup lists it.
    struct Summary {
        let json: JSONValue
        let status: String
    }

    /// The exams as Exam setup lists them, each as it reads at `now`, with its answers counted and its exam page.
    static func summaries(_ tx: StoreTransaction, _ rows: [ExamRow], folders: [FolderRow], pages: [PageViews.Page], now: Date) throws -> [Summary] {
        let answered = try ExamStore.answeredCounts(tx, rows.map(\.id))
        return try rows.map { row in
            let folderIDs = liveFolderIDs(row, folders)
            let page = pageOf(folderIDs: folderIDs, weeks: row.weeks, pages)
            return summary(try ExamStore.asRead(tx, row, now), now: now, answered: answered[row.id] ?? 0, folderIDs: folderIDs, pageID: page)
        }
    }

    /// The folders an exam was over that are still in the course, in its order: an empty folder
    /// removed since drops out, so the exam keeps the page of the ones left. Nil for an exam from before folders.
    static func liveFolderIDs(_ exam: ExamRow, _ folders: [FolderRow]) -> [String]? {
        exam.folderIds.map { ids in folders.filter { Set(ids).contains($0.id) }.map(\.id) }
    }

    /// The exam page an exam belongs to: the one holding every folder it was over (that is still in the
    /// course). An exam from before folders names weeks instead, matched against each page's folder
    /// names. Nil when no page does.
    static func pageOf(folderIDs: [String]?, weeks: [String]?, _ pages: [PageViews.Page]) -> String? {
        if let ids = folderIDs {
            if ids.isEmpty { return nil }
            return pages.first { page in ids.allSatisfy { id in page.folders.contains { $0.id == id } } }?.row.id
        }
        let names = weeks ?? []
        if names.isEmpty { return nil }
        return pages.first { page in names.allSatisfy { name in page.folders.contains { $0.name == name } } }?.row.id
    }

    /// `exam` is the row as read (`ExamStore.asRead`).
    static func summary(_ exam: ExamRow, now: Date, answered: Int, folderIDs: [String]?, pageID: String?) -> Summary {
        let status = exam.status(now).read
        let score = readScore(exam.score)
        let json: JSONValue = .object([
            "id": .string(exam.id), "courseId": .string(exam.courseId), "weeks": .array((exam.weeks ?? []).map(JSONValue.string)),
            "folderIds": folderIDs.map { .array($0.map(JSONValue.string)) } ?? .null, "courseExamId": .optional(pageID), "pool": .string(exam.pool),
            "practiceWeeks": exam.practiceWeeks.map { .array($0.map(JSONValue.string)) } ?? .null, "questionCount": .int(exam.questionIds.count),
            "timeLimitSeconds": .int(exam.limitSeconds ?? 0), "startedAt": .string(exam.startedAt), "endsAt": .string(ExamClock.text(milliseconds: exam.endsAt)),
            "status": .string(status), "finishedAt": .optional(exam.finishedAt), "endReason": .optional(readReason(exam.endReason)), "answeredCount": .int(answered),
            "fullyRight": score.map { .int($0.fullyRight) } ?? .null, "points": score.map { .int($0.points) } ?? .null,
            "maxPoints": score.map { .int($0.maxPoints) } ?? .null, "minutesUsed": score.map { .int($0.minutesUsed) } ?? .null,
        ])
        return Summary(json: json, status: status)
    }

    /// An exam's summary as the course reads it now, in whichever of the person's courses it is.
    static func summary(_ tx: StoreTransaction, _ exam: ExamRow, now: Date) throws -> Summary {
        let folders = try FolderOrder.rows(tx, courseID: exam.courseId)
        let pages = try PageViews.pages(tx, courseID: exam.courseId)
        guard let summary = try summaries(tx, [exam], folders: folders, pages: pages, now: now).first else { throw BankRefusal.failed }
        return summary
    }

    private struct StoredScore {
        let fullyRight: Int
        let points: Int
        let maxPoints: Int
        let minutesUsed: Int
    }

    private static func readScore(_ value: JSONValue?) -> StoredScore? {
        guard case .object(let fields)? = value else { return nil }
        let keys = ["questionCount", "answered", "fullyRight", "points", "maxPoints", "minutesUsed", "reviewCount"]
        guard keys.allSatisfy({ fields[$0]?.intValue != nil }) else { return nil }
        return StoredScore(
            fullyRight: fields["fullyRight"]?.intValue ?? 0, points: fields["points"]?.intValue ?? 0, maxPoints: fields["maxPoints"]?.intValue ?? 0,
            minutesUsed: fields["minutesUsed"]?.intValue ?? 0)
    }

    private static func readReason(_ value: String?) -> String? {
        value.flatMap { ["finished", "left", "timeout"].contains($0) ? $0 : nil }
    }

    // MARK: One exam

    /// One exam: its questions, and once it has ended, the result.
    static func view(_ tx: StoreTransaction, _ stored: ExamRow, now: Date) throws -> JSONValue {
        let exam = try ExamStore.asRead(tx, stored, now)
        let course = try StudyLookup.course(tx, exam.courseId)
        let folders = try FolderOrder.rows(tx, courseID: exam.courseId)
        let served = try ExamStore.served(tx, exam)
        let views = try StudyViews.questions(tx, rows: served.rows)
        let answers = try ExamStore.answers(tx, exam.id)
        let questions = zip(views, served.rows).enumerated().map { index, pair -> JSONValue in
            guard case .object(var fields) = pair.0 else { return pair.0 }
            fields["position"] = .int(index + 1)
            fields["weekLabel"] = .string(pair.1.string("week_label"))
            return .object(fields)
        }
        let result = try exam.finishedAt.map { try ExamScoring.score(exam, served: served, answers: answers, finishedAt: $0, folders: folders).json } ?? .null
        return .object([
            "id": .string(exam.id), "courseId": .string(exam.courseId), "courseCode": .string(course.code), "courseTitle": .string(course.title),
            "weeks": .array((exam.weeks ?? []).map(JSONValue.string)), "folderIds": liveFolderIDs(exam, folders).map { .array($0.map(JSONValue.string)) } ?? .null,
            "pool": .string(exam.pool), "practiceWeeks": exam.practiceWeeks.map { .array($0.map(JSONValue.string)) } ?? .null,
            "timeLimitSeconds": .int(exam.limitSeconds ?? 0), "startedAt": .string(exam.startedAt), "endsAt": .string(ExamClock.text(milliseconds: exam.endsAt)),
            "status": .string(exam.status(now).read), "finishedAt": .optional(exam.finishedAt), "endReason": .optional(readReason(exam.endReason)),
            "serverNow": .string(QBankJSON.formatDate(now)), "questions": .array(questions),
            "answeredQuestionIds": .array(answers.map { .string($0.string("question_id")) }), "result": result,
        ])
    }
}

extension JSONValue {
    /// A whole number, or nil.
    var intValue: Int? {
        guard case .number(let number) = self, number.isFinite, number == number.rounded(), abs(number) < 9e15 else { return nil }
        return Int(number)
    }
}
