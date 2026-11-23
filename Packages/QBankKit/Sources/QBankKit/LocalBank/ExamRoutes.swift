import Foundation

/// The rule family for exams: the plan and the pools they draw from, start and replace, running,
/// grace and time up from the clock, finish, the result by folder, past exams, and deleting one.
///
/// Only an exam's end is stored. Running, grace and time up are told from the clock the bank was
/// given, and the end of an exam whose time is up is recorded by the next read of the person's
/// exams, as the server does.
enum ExamRoutes {
    static func register(in router: inout BankRouter) {
        router.get("/api/courses/:id/exams", writes: true, setup)
        router.post("/api/courses/:id/exams", start)
        router.get("/api/exams/:id", writes: true, read)
        router.post("/api/exams/:id/finish", finish)
        router.get("/api/exams/:id/delete-preview", writes: true, previewDelete)
        router.delete("/api/exams/:id", delete)
        router.post("/api/exams/:id/undo-delete", undoDelete)
    }

    private static let pools = ["all", "wrong"]

    // MARK: Exam setup

    /// The course's folders with what an exam over each draws from, the running exam and the past
    /// ones, and, when folders are named, the exam that starting over them would give.
    private static func setup(_ call: BankCall) throws -> BankAnswer {
        let courseID = try BankBody.pathID(call)
        let selection = try setupSelection(call)
        _ = try StudyLookup.course(call.tx, courseID)
        try ExamStore.settleExpired(call)
        do {
            return .ok(try ExamViews.setup(call, courseID: courseID, selection: selection))
        } catch let refusal as BankRefusal {
            // The end recorded above stays, as it does on the server: a refused read is not an undone one.
            return BankAnswer(status: refusal.status, body: refusal.body)
        }
    }

    private static func setupSelection(_ call: BankCall) throws -> ExamViews.Selection? {
        let folderIDs = call.queryLists["folderIds"]
        let weeks = call.queryLists["weeks"]
        if let folderIDs, folderIDs.count > 200 || !folderIDs.allSatisfy(BankBody.isUUID) { throw BankRefusal.invalidRequest }
        if let weeks, weeks.count > 200 { throw BankRefusal.invalidRequest }
        var pool = "all"
        if let sent = call.query["pool"] {
            guard pools.contains(sent) else { throw BankRefusal.invalidRequest }
            pool = sent
        }
        guard folderIDs != nil || weeks != nil else { return nil }
        return ExamViews.Selection(folderIDs: folderIDs, weeks: weeks, pool: pool)
    }

    // MARK: Starting an exam

    /// Starts an exam over the folders ticked: questions drawn only from the sets in those folders,
    /// in proportion to each folder's size, in a shuffled order. A folder with an exam bank gives its
    /// exam-bank questions, and a folder without one its practice questions. The `wrong` pool keeps
    /// only the questions last answered not fully right, and refuses a folder that has none.
    ///
    /// An open exam (running, or in its grace) ends first, as if it had been left, only as `replaces`
    /// allows: absent (an app from before it) ends it unasked; an id ends it only when it names the
    /// open exam, the one confirmed; null starts only when none is open. Otherwise the start is
    /// refused with the open exam named, and nothing changes. An exam whose time is up is not open:
    /// it ends as a timeout whatever `replaces` says.
    private static func start(_ call: BankCall) throws -> BankAnswer {
        let fields = try BankBody(call.body)
        let selection = ExamViews.Selection(
            folderIDs: try fields.optionalUUIDs("folderIds", max: 200), weeks: try fields.optionalStrings("weeks", max: 200),
            pool: try fields.optionalChoice("pool", pools) ?? "all")
        let replaces = try fields.nullableUUID("replaces")
        let courseID = try BankBody.pathID(call)
        let tx = call.tx
        _ = try StudyLookup.course(tx, courseID)
        let course = try ExamViews.CoursePools.load(tx, courseID: courseID)
        let wanted = Set(try ExamViews.chosenFolders(course, selection, strict: true))
        func drawFrom(_ folderID: String) -> [String] { course.pools[folderID]?.questions(selection.pool) ?? [] }
        let ticked = course.folders.filter { wanted.contains($0.id) }
        // A ticked folder with nothing in the pool is refused. A legacy name is refused only when none
        // of its folders has anything; the others of that name are left out.
        var empty: [String] = []
        for folder in ticked where drawFrom(folder.id).isEmpty && !empty.contains(folder.name) {
            if selection.weeks == nil || ticked.filter({ $0.name == folder.name }).allSatisfy({ drawFrom($0.id).isEmpty }) { empty.append(folder.name) }
        }
        if !empty.isEmpty {
            let one = empty.count == 1
            throw BankRefusal.study(
                400, "no_wrong_questions", "\(BankText.list(empty)) \(one ? "has" : "have") no wrong questions. Untick \(one ? "it" : "them"), or turn off Wrong questions only.")
        }
        let drawing = ticked.filter { !drawFrom($0.id).isEmpty }
        // Every folder left holds questions in the pool, so the plan covers them all.
        let plan = ExamViews.plan(course, folderIDs: drawing.map(\.id), pool: selection.pool)
        let drawn = call.shuffled(plan.draws.flatMap { draw in Array(call.shuffled(drawFrom(draw.id)).prefix(draw.drawn)) })
        // The names as seen: the folders' names in the course's order, or the weeks ticked.
        var names: [String] = []
        for folder in drawing where !names.contains(folder.name) { names.append(folder.name) }
        if selection.weeks != nil {
            names = names.enumerated().sorted { a, b in
                let byWeek = BankText.compareWeeks(a.element, b.element)
                return byWeek != 0 ? byWeek < 0 : a.offset < b.offset
            }.map(\.element)
        }

        let open = try ExamStore.open(tx)
        if !replaces.isAbsent {
            let replacing: String? = if case .value(let id) = replaces { id } else { nil }
            if let unconfirmed = open.first(where: { ExamClock.isOpen($0.status(call.now)) && $0.id != replacing }) {
                return BankAnswer(status: 409, body: try inProgress(tx, unconfirmed, now: call.now))
            }
        }
        for exam in open { try ExamStore.close(call, exam, reason: "left") }
        let id = call.newID()
        try tx.execute(
            """
            INSERT INTO study_session (id, course_id, mode, set_id, question_ids, exam_weeks, exam_folder_ids, time_limit_seconds, started_at, finished_at, score, end_reason, exam_pool, exam_practice_weeks)
            VALUES (?, ?, 'exam', NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
            """,
            [
                .text(id), .text(courseID), .text(list(drawn)), .text(list(names)), .text(list(drawing.map(\.id))), .integer(Int64(plan.plan.timeLimitSeconds)),
                .text(call.nowText), .text(selection.pool), plan.practiceWeeks.map { .text(list($0)) } ?? .null,
            ])
        return .created(try ExamViews.view(tx, try ExamStore.live(tx, id), now: call.now))
    }

    /// The 409 that names the exam still open, which starting another would end.
    private static func inProgress(_ tx: StoreTransaction, _ exam: ExamRow, now: Date) throws -> JSONValue {
        .object([
            "error": .string("exam_in_progress"), "message": .string("An exam is still running. Starting a new one ends it, so confirm that first."),
            "inProgress": try ExamViews.summary(tx, exam, now: now).json,
        ])
    }

    private static func list(_ items: [String]) -> String { Stored.json(.array(items.map(JSONValue.string))) }

    // MARK: Reading and ending

    /// One exam: its questions, and once it has ended, the result. An exam whose time is up has its end recorded first.
    private static func read(_ call: BankCall) throws -> BankAnswer {
        let id = try BankBody.pathID(call)
        try ExamStore.settleExpired(call)
        return .ok(try ExamViews.view(call.tx, try ExamStore.live(call.tx, id), now: call.now))
    }

    /// Ends the exam and scores what was answered. Ending one that has already ended returns it
    /// unchanged. After its time is up, the end is recorded as a timeout at the moment time ran out.
    private static func finish(_ call: BankCall) throws -> BankAnswer {
        let fields = try BankBody(call.body)
        guard let reason = try fields.optionalChoice("reason", ["finished", "left", "timeout"]) else { throw BankRefusal.invalidRequest }
        let id = try BankBody.pathID(call)
        let exam = try ExamStore.live(call.tx, id)
        if exam.status(call.now) != .ended { try ExamStore.close(call, exam, reason: reason) }
        return .ok(try ExamViews.view(call.tx, try ExamStore.live(call.tx, id), now: call.now))
    }

    // MARK: Deleting a past exam

    private static func previewDelete(_ call: BankCall) throws -> BankAnswer {
        .ok(try ExamDeletions.preview(call, examID: try BankBody.pathID(call)))
    }

    private static func delete(_ call: BankCall) throws -> BankAnswer {
        let id = try BankBody.pathID(call)
        let confirm = call.query["confirm"]
        if let confirm, confirm.utf16.count > 64 { throw BankRefusal.invalidRequest }
        try ExamDeletions.delete(call, examID: id, confirm: confirm)
        return BankAnswer(status: 204, body: nil)
    }

    private static func undoDelete(_ call: BankCall) throws -> BankAnswer {
        .ok(try ExamDeletions.undo(call, examID: try BankBody.pathID(call)))
    }
}
