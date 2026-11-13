#if DEBUG
import Foundation
import QBankKit

/// Deleting a course or topic on the fake server, its Undo, and Home's Recently deleted.
nonisolated extension FakeQBankServer {
    // MARK: Deleting a course or topic, with the rules and words of the server's `content/deletions.ts`

    /// The course delete, its Undo and Home's Recently deleted, and every other read of a deleted
    /// course, which answers as an id that names nothing; nil for any other route.
    func courseDeletion(method: String, path: String, query: [String: String], email: String) -> Reply? {
        if method == "GET", path == "/api/deleted-courses" { return (200, deletedCourses()) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api", parts[1] == "courses" else { return nil }
        let id = parts[2]
        let action = parts.count == 4 ? parts[3] : nil
        let course = state.withLock { state in state.courses.first { $0.id == id } }
        if method == "POST", action == "undo-delete" { return undoCourseDelete(id) }
        if let course, course.deletedAt != nil {
            return failure(404, "course_not_found", "That course is not in the app.")
        }
        switch (method, action) {
        case ("GET", "delete-preview"):
            guard let course else { return failure(404, "course_not_found", "That course is not in the app.") }
            return (200, coursePreview(course, email: email))
        case ("DELETE", nil):
            guard let course else { return failure(404, "course_not_found", "That course is not in the app.") }
            return deleteCourse(course, confirm: query["confirm"], email: email)
        default:
            return nil
        }
    }

    private func coursePreview(_ course: FakeCourse, email: String) -> [String: Any] {
        let card = state.withLock { state in courseJSON(course, in: state) }
        let questions = card["questionCount"] as? Int ?? 0
        let name = Self.name(course)
        let folders = study.knows(course.id) ? study.folders(course.id) : []
        let semester = state.withLock { state in state.semesters.first { $0.id == course.semesterID } }
        let warning = FakeDeletions.Warning([
            "Delete \(questions == 0 ? name : "\(name) and its \(Wording.count(questions, "question"))")?",
            "You can bring it back for \(FakeDeletions.undoDays) days.",
        ])
        return [
            "courseId": course.id, "kind": course.kind, "code": course.code, "title": course.title,
            "semester": semester.map { ["id": $0.id, "number": $0.number, "name": $0.name] as Any } ?? NSNull(),
            "folderCount": card["folderCount"] as? Int ?? 0, "examPageCount": study.courseExamsJSON(course.id).count,
            "setCount": folders.reduce(0) { $0 + $1.sets.count }, "questionCount": questions, "examQuestionCount": 0,
            "answeredCount": card["answeredCount"] as? Int ?? 0, "reviewCount": card["reviewCount"] as? Int ?? 0,
            "pastExamCount": folders.reduce(0) { $0 + study.pastExams(over: $1.id, courseID: course.id) },
            "message": warning.message, "warning": warning.json,
            "refusal": json(courseInUse(course, email: email)), "confirm": Self.courseToken(course, questions: questions), "undoDays": FakeDeletions.undoDays,
        ]
    }

    /// The sentence refusing to delete it now: a job still working in it, or an exam in it still going.
    private func courseInUse(_ course: FakeCourse, email: String) -> String? {
        let name = Self.name(course)
        if twinJobs.isWorking(courseID: course.id, email: email) {
            return "QBank is still writing exam twins in \(name). Wait until they are filed, or cancel them, first."
        }
        if questionMaker.isWorking(courseID: course.id, email: email) {
            return "QBank is still making a set in \(name). Wait until it is filed, or cancel it, first."
        }
        return study.runningExams(courseID: course.id).isEmpty ? nil : "An exam in \(name) is still going. Finish or leave that exam first."
    }

    /// A short fingerprint of what deleting it takes, as the server's: 16 hex digits.
    private static func courseToken(_ course: FakeCourse, questions: Int) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ["course", course.id, course.kind, course.code, course.title, String(questions)].joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func deleteCourse(_ course: FakeCourse, confirm: String?, email: String) -> Reply {
        if let refusal = courseInUse(course, email: email) { return failure(409, "in_use", refusal) }
        let name = Self.name(course)
        guard let confirm else {
            return failure(409, "confirmation_required", "Look at what goes with \(name) and confirm it before deleting it.")
        }
        let questions = state.withLock { state in courseJSON(course, in: state)["questionCount"] as? Int ?? 0 }
        guard confirm == Self.courseToken(course, questions: questions) else {
            return failure(409, "deletion_changed", "\(name) changed since you were warned. Look again before deleting it.")
        }
        state.withLock { state in
            guard let index = state.courses.firstIndex(where: { $0.id == course.id }) else { return }
            state.courses[index].deletedAt = .now
        }
        return (204, [:])
    }

    private func undoCourseDelete(_ id: String) -> Reply {
        state.withLock { state in
            guard let index = state.courses.firstIndex(where: { $0.id == id }) else {
                return failure(404, "course_not_found", "That course is not in the app.")
            }
            let course = state.courses[index]
            guard course.deletedAt != nil else { return failure(409, "request_refused", "\(Self.name(course)) is not deleted.") }
            if let refusal = courseUndoRefusal(course, in: state) { return failure(409, refusal.code, refusal.message) }
            state.courses[index].deletedAt = nil
            return (200, courseJSON(state.courses[index], in: state))
        }
    }

    /// Why Undo cannot bring it back now: too late, or its code or name is taken now.
    private func courseUndoRefusal(_ course: FakeCourse, in state: State) -> (code: String, message: String)? {
        let name = Self.name(course)
        if let deletedAt = course.deletedAt, Date.now > Self.undoUntil(deletedAt) {
            return ("undo_expired", "\(name) was deleted more than \(FakeDeletions.undoDays) days ago, so it can't be brought back.")
        }
        let live = state.courses.filter { $0.id != course.id && $0.deletedAt == nil && $0.kind == course.kind }
        if course.kind == "topic" {
            guard let clash = live.first(where: { $0.title.lowercased() == course.title.lowercased() }) else { return nil }
            return ("request_refused", "You already have a topic named \(clash.title). Rename one of them, then bring this one back.")
        }
        guard let clash = live.first(where: { $0.semesterID == course.semesterID && $0.code.lowercased() == course.code.lowercased() }) else { return nil }
        let semester = state.semesters.first { $0.id == course.semesterID }?.name ?? "This semester"
        return ("request_refused", "\(semester) already has a course with the code \(clash.code). Rename one of them, then bring this one back.")
    }

    private static func undoUntil(_ deletedAt: Date) -> Date {
        deletedAt.addingTimeInterval(TimeInterval(FakeDeletions.undoDays) * 86_400)
    }

    /// Her courses and topics deleted in the last 30 days, newest first.
    private func deletedCourses() -> [String: Any] {
        state.withLock { state in
            let deleted = state.courses.compactMap { course in course.deletedAt.map { (course, $0) } }
                .filter { Date.now <= Self.undoUntil($0.1) }
                .sorted { $0.1 > $1.1 }
            return [
                "undoDays": FakeDeletions.undoDays,
                "courses": deleted.map { course, deletedAt -> [String: Any] in
                    let semester = state.semesters.first { $0.id == course.semesterID }
                    return [
                        "id": course.id, "kind": course.kind, "code": course.code, "title": course.title,
                        "semester": semester.map { ["id": $0.id, "number": $0.number, "name": $0.name] as Any } ?? NSNull(),
                        "questionCount": courseJSON(course, in: state)["questionCount"] as? Int ?? 0,
                        "deletedAt": QBankJSON.formatDate(deletedAt), "undoUntil": QBankJSON.formatDate(Self.undoUntil(deletedAt)),
                        "undoRefusal": json(courseUndoRefusal(course, in: state)?.message), "deletedByAgent": NSNull(),
                    ]
                },
            ]
        }
    }
}
#endif
