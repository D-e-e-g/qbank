#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// What the fake server's deletes need from the rest of it: her sets' titles, sizes and answers,
/// and a folder as a reply draws it.
nonisolated protocol FakeDeletionLibrary {
    /// A practice set's title, size, answered questions, and versions.
    func deletionSet(_ id: String) -> (title: String, questionCount: Int, answeredCount: Int, versionCount: Int)?
    func examSetTitle(_ id: String) -> String
    func folderReply(_ folder: FakeStudy.Folder) -> [String: Any]
}

/// The fake server's deletes and Undo, with the rules and words of the real routes
/// (`content/deletions.ts`, `exams/deletions.ts`): a preview names what goes and hands out a
/// `confirm`, the delete takes exactly that or is refused when it changed, and Undo brings it back
/// for 30 days. A delete takes the set, folder, exam page or exam out of `FakeStudy`, so every read
/// leaves it out, and keeps it here to put back. An exam page goes alone: its folders stay in the
/// course, on no page, until Undo puts them back on it.
nonisolated final class FakeDeletions: Sendable {
    typealias Reply = (Int, [String: Any])

    static let undoDays = 30

    /// One delete, with what Undo puts back.
    struct Deleted {
        enum Kind {
            case set(id: String, title: String, folderID: String, folderName: String, index: Int, questionCount: Int)
            case examSet(id: String, title: String, folderID: String, folderName: String, questionIDs: [String])
            /// A folder, with the sets that went with it, practice sets then exam sets.
            case folder(FakeStudy.Folder, sets: [(id: String, title: String, kind: String, questionCount: Int)])
            /// An exam page, with its folders as they were on it, for Undo to put back.
            case examPage(FakeStudy.CourseExam, folders: [(id: String, sortOrder: Int)])
            /// The exam, and as Exam setup listed it, in JSON.
            case exam(FakeStudy.Exam, summary: Data)
        }

        let kind: Kind
        let courseID: String
        let at: Date

        var undoUntil: Date { at.addingTimeInterval(TimeInterval(FakeDeletions.undoDays) * 86_400) }
    }

    private let deleted = Mutex<[Deleted]>([])
    private let study: FakeStudy
    private let now: @Sendable () -> Date

    init(study: FakeStudy, now: @escaping @Sendable () -> Date = { .now }) {
        self.study = study
        self.now = now
    }

    /// Answers the delete, Undo and Recently deleted routes; nil for any other route.
    func answer(method: String, path: String, query: [String: String], isStudent: Bool, library: some FakeDeletionLibrary) -> Reply? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "api" else { return nil }
        let id = parts[2]
        let action = parts.count == 4 ? parts[3] : nil
        switch (method, parts[1], action) {
        case ("GET", "practice-sets", "delete-preview"): return Self.reply(setPreview(id, library))
        case ("DELETE", "practice-sets", nil): return deleteSet(id, confirm: query["confirm"], library)
        case ("POST", "practice-sets", "undo-delete"): return undoSet(id, library)
        case ("GET", "folders", "delete-preview"): return Self.reply(folderPreview(id, library))
        case ("DELETE", "folders", nil): return deleteFolder(id, confirm: query["confirm"], library)
        case ("POST", "folders", "undo-delete"): return undoFolder(id, library)
        case ("GET", "course-exams", "delete-preview"): return Self.reply(pagePreview(id, library))
        case ("DELETE", "course-exams", nil): return deletePage(id, confirm: query["confirm"])
        case ("POST", "course-exams", "undo-delete"): return undoPage(id)
        case ("GET", "exams", "delete-preview"): return Self.reply(examPreview(id))
        case ("DELETE", "exams", nil): return isStudent ? deleteExam(id, confirm: query["confirm"]) : Self.adminRefused
        case ("POST", "exams", "undo-delete"): return isStudent ? undoExam(id) : Self.adminRefused
        case ("GET", "courses", "deleted") where study.knows(id): return recentlyDeleted(id)
        default: return nil
        }
    }

    private static var adminRefused: Reply { failure(403, "admin_cannot_delete_exam", "Only the student can delete her exams or bring them back.") }

    // MARK: Sets

    private struct SetPlan {
        let id: String
        let title: String
        let isExam: Bool
        let folder: FakeStudy.Folder
        let questionIDs: [String]
        let answeredCount: Int
        let versionCount: Int
        let confirm: String
    }

    private func setPlan(_ id: String, _ library: some FakeDeletionLibrary) -> Result<SetPlan, Refusal> {
        if let folder = study.folder(holding: id), let set = library.deletionSet(id) {
            let questionIDs = FakeStudy.ids(id, set.questionCount)
            return .success(SetPlan(
                id: id, title: set.title, isExam: false, folder: folder, questionIDs: questionIDs, answeredCount: set.answeredCount,
                versionCount: set.versionCount, confirm: Self.token(["set", id, set.title, folder.id])
            ))
        }
        if let (folder, questionIDs) = study.folder(holdingExamSet: id) {
            let title = library.examSetTitle(id)
            return .success(SetPlan(
                id: id, title: title, isExam: true, folder: folder, questionIDs: questionIDs, answeredCount: 0,
                versionCount: 1, confirm: Self.token(["set", id, title, folder.id, String(questionIDs.count)])
            ))
        }
        if isDeleted(set: id) { return .failure(Refusal(404, "request_refused", "That set was deleted.")) }
        return .failure(Refusal(404, "request_refused", "That set is not in the app."))
    }

    private func setPreview(_ id: String, _ library: some FakeDeletionLibrary) -> Result<[String: Any], Refusal> {
        setPlan(id, library).map { plan in
            let review = plan.isExam ? 0 : study.inReview(Set(plan.questionIDs), courseID: plan.folder.courseID)
            let lastBank = plan.isExam && FakeStudy.examSets(plan.folder).count == 1
            let warning = Self.setWarning(
                title: plan.title, folder: plan.folder.name, isExam: plan.isExam, questionCount: plan.questionIDs.count,
                versionCount: plan.versionCount, answeredCount: plan.answeredCount, reviewCount: review, lastBank: lastBank
            )
            return [
                "setId": plan.id, "title": plan.title, "kind": plan.isExam ? "exam" : "practice", "folderId": plan.folder.id,
                "folderName": plan.folder.name, "examPageId": Self.json(plan.folder.examPageID), "questionCount": plan.questionIDs.count,
                "versionCount": plan.versionCount, "answeredCount": plan.answeredCount, "reviewCount": review,
                "progress": standing(courseID: plan.folder.courseID, answered: plan.answeredCount, review: review),
                "message": warning.message, "warning": warning.json,
                "refusal": Self.json(inUse(plan.questionIDs, courseID: plan.folder.courseID, name: plan.title)),
                "confirm": plan.confirm, "undoDays": Self.undoDays,
            ]
        }
    }

    private func deleteSet(_ id: String, confirm: String?, _ library: some FakeDeletionLibrary) -> Reply {
        let plan: SetPlan
        switch setPlan(id, library) {
        case .success(let found): plan = found
        case .failure(let refusal): return refusal.reply
        }
        if let refusal = inUse(plan.questionIDs, courseID: plan.folder.courseID, name: plan.title) {
            return Self.failure(409, "in_use", refusal)
        }
        if let refusal = Self.confirmed(confirm, plan.confirm, name: plan.title) { return refusal.reply }
        let kind: Deleted.Kind
        if plan.isExam {
            guard let taken = study.take(examSet: id) else { return Self.failure(404, "request_refused", "That set is not in the app.") }
            kind = .examSet(id: id, title: plan.title, folderID: taken.folderID, folderName: plan.folder.name, questionIDs: taken.questionIDs)
        } else {
            guard let taken = study.take(set: id) else { return Self.failure(404, "request_refused", "That set is not in the app.") }
            kind = .set(id: id, title: plan.title, folderID: taken.folderID, folderName: plan.folder.name, index: taken.index, questionCount: plan.questionIDs.count)
        }
        deleted.withLock { $0.append(Deleted(kind: kind, courseID: plan.folder.courseID, at: now())) }
        return (204, [:])
    }

    private func undoSet(_ id: String, _ library: some FakeDeletionLibrary) -> Reply {
        let found = deleted.withLock { list -> (Int, Deleted)? in
            list.enumerated().first { _, entry in
                switch entry.kind {
                case .set(let setID, _, _, _, _, _), .examSet(let setID, _, _, _, _): setID == id
                default: false
                }
            }.map { ($0.offset, $0.element) }
        }
        guard let (index, entry) = found else {
            if let folder = deletedFolder(holding: id) {
                let title = folder.sets.first { $0.id == id }?.title ?? "That set"
                return Self.failure(409, "request_refused", "\(title) went with its folder \(folder.folder.name). Bring the folder back to bring it back.")
            }
            return study.folder(holding: id) != nil || study.folder(holdingExamSet: id) != nil
                ? Self.failure(409, "request_refused", "That set is not deleted.")
                : Self.failure(404, "request_refused", "That set is not in the app.")
        }
        if let refusal = setUndoRefusal(entry) { return Self.failure(409, refusal.code, refusal.message) }
        let folderID: String
        switch entry.kind {
        case .set(_, _, let folder, _, let position, _):
            study.putBack(set: id, in: folder, at: position)
            folderID = folder
        case .examSet(_, _, let folder, _, let questionIDs):
            study.putBack(bank: questionIDs, in: folder)
            folderID = folder
        default:
            return Self.failure(404, "request_refused", "That set is not in the app.")
        }
        deleted.withLock { _ = $0.remove(at: index) }
        guard let folder = study.folder(folderID) else { return Self.failure(404, "request_refused", "That folder is not in the app.") }
        return (200, library.folderReply(folder))
    }

    private func setUndoRefusal(_ entry: Deleted) -> (code: String, message: String)? {
        let (title, folderID, folderName): (String, String, String)
        switch entry.kind {
        case .set(_, let name, let folder, let folderLabel, _, _), .examSet(_, let name, let folder, let folderLabel, _):
            (title, folderID, folderName) = (name, folder, folderLabel)
        default:
            return nil
        }
        if now() > entry.undoUntil {
            return ("undo_expired", "\(title) was deleted more than \(Self.undoDays) days ago, so it can't be brought back.")
        }
        if study.folder(folderID) == nil {
            return ("request_refused", "Its folder \(folderName) is deleted. Bring the folder back first.")
        }
        return nil
    }

    private func isDeleted(set id: String) -> Bool {
        deleted.withLock { list in
            list.contains { entry in
                switch entry.kind {
                case .set(let setID, _, _, _, _, _), .examSet(let setID, _, _, _, _): setID == id
                case .folder(_, let sets): sets.contains { $0.id == id }
                case .examPage, .exam: false
                }
            }
        }
    }

    // MARK: Folders

    private struct FolderPlan {
        let folder: FakeStudy.Folder
        let pageName: String?
        let sets: [(id: String, title: String, kind: String, questionCount: Int, answeredCount: Int)]
        let questionIDs: [String]
        let confirm: String
    }

    private func folderPlan(_ id: String, _ library: some FakeDeletionLibrary) -> Result<FolderPlan, Refusal> {
        guard let folder = study.folder(id) else {
            return .failure(deletedFolder(id) != nil ? Refusal(404, "request_refused", "That folder was deleted.") : Refusal(404, "request_refused", "That folder is not in the app."))
        }
        let practice = folder.sets.compactMap { setID in
            library.deletionSet(setID).map { (id: setID, title: $0.title, kind: "practice", questionCount: $0.questionCount, answeredCount: $0.answeredCount) }
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        let exams = FakeStudy.examSets(folder).map { set in
            (id: set.id, title: library.examSetTitle(set.id), kind: "exam", questionCount: set.questionIDs.count, answeredCount: 0)
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        let sets = practice + exams
        let questionIDs = folder.sets.flatMap { FakeStudy.ids($0, library.deletionSet($0)?.questionCount ?? 0) } + folder.bank
        let pageName = folder.examPageID.flatMap { page in
            study.courseExamsJSON(folder.courseID).first { $0["id"] as? String == page }?["name"] as? String
        }
        return .success(FolderPlan(
            folder: folder, pageName: pageName, sets: sets, questionIDs: questionIDs,
            confirm: Self.token(["folder", folder.id, folder.name, folder.examPageID ?? ""] + sets.map { "\($0.id):\($0.title):\($0.questionCount)" }.sorted())
        ))
    }

    private func folderPreview(_ id: String, _ library: some FakeDeletionLibrary) -> Result<[String: Any], Refusal> {
        folderPlan(id, library).map { plan in
            let answered = plan.sets.reduce(0) { $0 + $1.answeredCount }
            let review = study.inReview(Set(plan.questionIDs), courseID: plan.folder.courseID)
            let pastExams = study.pastExams(over: plan.folder.id, courseID: plan.folder.courseID)
            let questions = plan.sets.reduce(0) { $0 + $1.questionCount }
            let warning = Self.folderWarning(
                name: plan.folder.name, page: plan.pageName, titles: plan.sets.map(\.title), questionCount: questions,
                answeredCount: answered, reviewCount: review, pastExamCount: pastExams
            )
            return [
                "folderId": plan.folder.id, "name": plan.folder.name, "examPageId": Self.json(plan.folder.examPageID),
                "examPageName": Self.json(plan.pageName),
                "sets": plan.sets.map { ["id": $0.id, "title": $0.title, "kind": $0.kind, "questionCount": $0.questionCount, "answeredCount": $0.answeredCount] },
                "setCount": plan.sets.count, "questionCount": questions, "answeredCount": answered, "reviewCount": review,
                "pastExamCount": pastExams,
                "progress": standing(courseID: plan.folder.courseID, answered: answered, review: review),
                "message": warning.message, "warning": warning.json,
                "refusal": Self.json(inUse(plan.questionIDs, courseID: plan.folder.courseID, name: plan.folder.name)),
                "confirm": plan.confirm, "undoDays": Self.undoDays,
            ]
        }
    }

    private func deleteFolder(_ id: String, confirm: String?, _ library: some FakeDeletionLibrary) -> Reply {
        let plan: FolderPlan
        switch folderPlan(id, library) {
        case .success(let found): plan = found
        case .failure(let refusal): return refusal.reply
        }
        if let refusal = inUse(plan.questionIDs, courseID: plan.folder.courseID, name: plan.folder.name) {
            return Self.failure(409, "in_use", refusal)
        }
        if confirm != nil || !plan.sets.isEmpty {
            let count = plan.sets.count
            let unconfirmed = "\(plan.folder.name) still has \(Wording.count(count, "set")). Deleting it deletes \(count == 1 ? "that set" : "them") too, so look at what goes and confirm it first."
            if let refusal = Self.confirmed(confirm, plan.confirm, name: plan.folder.name, unconfirmed: unconfirmed) { return refusal.reply }
        }
        guard let folder = study.take(folder: id) else { return Self.failure(404, "request_refused", "That folder is not in the app.") }
        let sets = plan.sets.map { (id: $0.id, title: $0.title, kind: $0.kind, questionCount: $0.questionCount) }
        deleted.withLock { $0.append(Deleted(kind: .folder(folder, sets: sets), courseID: folder.courseID, at: now())) }
        return (204, [:])
    }

    private func undoFolder(_ id: String, _ library: some FakeDeletionLibrary) -> Reply {
        let found = deleted.withLock { list -> (Int, FakeStudy.Folder, Date)? in
            for (index, entry) in list.enumerated() {
                if case .folder(let folder, _) = entry.kind, folder.id == id { return (index, folder, entry.undoUntil) }
            }
            return nil
        }
        guard let (index, folder, undoUntil) = found else {
            return study.folder(id) != nil
                ? Self.failure(409, "request_refused", "That folder is not deleted.")
                : Self.failure(404, "request_refused", "That folder is not in the app.")
        }
        if now() > undoUntil {
            return Self.failure(409, "undo_expired", "\(folder.name) was deleted more than \(Self.undoDays) days ago, so it can't be brought back.")
        }
        if let clash = study.putBack(folder: folder) { return Self.failure(409, "request_refused", clash) }
        deleted.withLock { _ = $0.remove(at: index) }
        guard let back = study.folder(id) else { return Self.failure(404, "request_refused", "That folder is not in the app.") }
        return (200, library.folderReply(back))
    }

    private func deletedFolder(_ id: String) -> FakeStudy.Folder? {
        deleted.withLock { list in
            list.lazy.compactMap { entry -> FakeStudy.Folder? in
                if case .folder(let folder, _) = entry.kind, folder.id == id { return folder }
                return nil
            }.first
        }
    }

    private func deletedFolder(holding setID: String) -> (folder: FakeStudy.Folder, sets: [(id: String, title: String, kind: String, questionCount: Int)])? {
        deleted.withLock { list in
            for entry in list {
                if case .folder(let folder, let sets) = entry.kind, sets.contains(where: { $0.id == setID }) { return (folder, sets) }
            }
            return nil
        }
    }

    // MARK: Exam pages

    private struct PagePlan {
        let page: FakeStudy.CourseExam
        let folders: [FakeStudy.Folder]
        let refusal: String?
        let confirm: String
    }

    private func pagePlan(_ id: String) -> Result<PagePlan, Refusal> {
        guard let (page, folders) = study.page(id) else {
            return .failure(deletedPage(id) != nil ? Refusal(404, "request_refused", "That exam page was deleted.") : Refusal(404, "request_refused", "That exam is not in the app."))
        }
        return .success(PagePlan(
            page: page, folders: folders, refusal: study.pageDeleteRefusal(id),
            confirm: Self.token(["exam-page", page.id, page.name] + folders.map { "\($0.id):\($0.name)" })
        ))
    }

    private func pagePreview(_ id: String, _ library: some FakeDeletionLibrary) -> Result<[String: Any], Refusal> {
        pagePlan(id).map { plan in
            let pastExams = study.pastExams(onPage: id)
            let practice = plan.folders.map { folder in folder.sets.compactMap(library.deletionSet) }
            let folders = zip(plan.folders, practice).map { folder, sets in
                [
                    "id": folder.id, "name": folder.name, "setCount": sets.count + FakeStudy.examSets(folder).count,
                    "questionCount": sets.reduce(0) { $0 + $1.questionCount } + folder.bank.count,
                ] as [String: Any]
            }
            let sets = practice.joined()
            // Nothing she answered is in the page itself, so her standing is the same before and after.
            let review = study.reviewCount(plan.page.courseID)
            let same = { (count: Int) in ["before": count, "after": count] }
            let warning = Self.pageWarning(name: plan.page.name, folders: plan.folders.map(\.name), pastExamCount: pastExams)
            return [
                "examPageId": plan.page.id, "courseId": plan.page.courseID, "name": plan.page.name, "folders": folders,
                "folderCount": plan.folders.count, "setCount": folders.reduce(0) { $0 + ($1["setCount"] as? Int ?? 0) },
                "questionCount": sets.reduce(0) { $0 + $1.questionCount }, "examQuestionCount": plan.folders.reduce(0) { $0 + $1.bank.count },
                "answeredCount": sets.reduce(0) { $0 + $1.answeredCount }, "pastExamCount": pastExams,
                "progress": [
                    "answeredCount": same(0), "fullyRightCount": same(0), "reviewCount": same(review),
                    "points": same(0), "maxPoints": same(0), "wrongCount": same(0),
                ],
                "message": warning.message, "warning": warning.json,
                "refusal": Self.json(plan.refusal), "confirm": plan.confirm, "undoDays": Self.undoDays,
            ]
        }
    }

    private func deletePage(_ id: String, confirm: String?) -> Reply {
        let plan: PagePlan
        switch pagePlan(id) {
        case .success(let found): plan = found
        case .failure(let refusal): return refusal.reply
        }
        if let refusal = plan.refusal { return Self.failure(409, "request_refused", refusal) }
        if confirm != nil || !plan.folders.isEmpty {
            let count = plan.folders.count
            let unconfirmed = "\(plan.page.name) still has \(Wording.count(count, "folder")). Deleting it puts \(count == 1 ? "that folder" : "them") under Folders, so look at what changes and confirm it first."
            if let refusal = Self.confirmed(confirm, plan.confirm, name: plan.page.name, unconfirmed: unconfirmed) { return refusal.reply }
        }
        guard let (page, folders) = study.take(page: id) else { return Self.failure(404, "request_refused", "That exam is not in the app.") }
        deleted.withLock { $0.append(Deleted(kind: .examPage(page, folders: folders), courseID: page.courseID, at: now())) }
        return (204, [:])
    }

    private func undoPage(_ id: String) -> Reply {
        let found = deleted.withLock { list -> (Int, FakeStudy.CourseExam, [(id: String, sortOrder: Int)], Date)? in
            for (index, entry) in list.enumerated() {
                if case .examPage(let page, let folders) = entry.kind, page.id == id { return (index, page, folders, entry.undoUntil) }
            }
            return nil
        }
        guard let (index, page, folders, undoUntil) = found else {
            return study.page(id).map { Self.failure(409, "request_refused", "\($0.page.name) is not deleted.") }
                ?? Self.failure(404, "request_refused", "That exam is not in the app.")
        }
        if let refusal = pageUndoRefusal(page, undoUntil: undoUntil) { return Self.failure(409, refusal.code, refusal.message) }
        if let clash = study.putBack(page: page, folders: folders) { return Self.failure(409, "request_refused", clash) }
        deleted.withLock { _ = $0.remove(at: index) }
        return (200, study.pageJSON(id) ?? [:])
    }

    /// Why Undo cannot bring the page back now: too late, or another page has its name.
    private func pageUndoRefusal(_ page: FakeStudy.CourseExam, undoUntil: Date) -> (code: String, message: String)? {
        if now() > undoUntil {
            return ("undo_expired", "\(page.name) was deleted more than \(Self.undoDays) days ago, so it can't be brought back.")
        }
        return study.pageNameClash(page).map { ("request_refused", $0) }
    }

    private func deletedPage(_ id: String) -> FakeStudy.CourseExam? {
        deleted.withLock { list in
            list.lazy.compactMap { entry -> FakeStudy.CourseExam? in
                if case .examPage(let page, _) = entry.kind, page.id == id { return page }
                return nil
            }.first
        }
    }

    // MARK: Past exams

    private static let inProgress = "This exam is still going. Finish or leave it, then delete it."

    private func examPlan(_ id: String) -> Result<FakeStudy.Exam, Refusal> {
        if let exam = study.exam(id) { return .success(exam) }
        let isDeleted = deleted.withLock { list in
            list.contains { entry in
                if case .exam(let exam, _) = entry.kind { return exam.id == id }
                return false
            }
        }
        return .failure(Refusal(404, "exam_not_found", isDeleted ? "That exam was deleted." : "That exam is not in the app."))
    }

    private static func examToken(_ exam: FakeStudy.Exam) -> String {
        token(["exam", exam.id, exam.finishedAt.map(QBankJSON.formatDate) ?? ""])
    }

    private func examPreview(_ id: String) -> Result<[String: Any], Refusal> {
        examPlan(id).map { exam in
            let answered = exam.answers.count
            // Questions she had answered before this run go back to that answer; the rest to none.
            let changed = exam.answers.keys.count { FakeStudy.wrongAtStart.contains($0) }
            let warning = Self.examWarning(answered: answered, changed: changed, unanswered: answered - changed)
            return [
                "examId": exam.id, "courseId": exam.courseID, "startedAt": QBankJSON.formatDate(exam.startedAt),
                "finishedAt": Self.json(exam.finishedAt.map(QBankJSON.formatDate)), "questionCount": exam.questions.count,
                "answeredCount": answered, "changedCount": changed, "unansweredCount": answered - changed,
                "progress": standing(courseID: exam.courseID, answered: 0, review: 0),
                "message": warning.message, "warning": warning.json,
                "refusal": exam.finishedAt == nil ? Self.inProgress : NSNull(),
                "confirm": Self.examToken(exam), "undoDays": Self.undoDays,
            ]
        }
    }

    private func deleteExam(_ id: String, confirm: String?) -> Reply {
        let exam: FakeStudy.Exam
        switch examPlan(id) {
        case .success(let found): exam = found
        case .failure(let refusal): return refusal.reply
        }
        if exam.finishedAt == nil { return Self.failure(409, "exam_in_progress", Self.inProgress) }
        guard let confirm else {
            return Self.failure(409, "confirmation_required", "Look at what deleting this exam changes and confirm it first.")
        }
        guard confirm == Self.examToken(exam) else {
            return Self.failure(409, "deletion_changed", "This exam changed since you were warned. Look again before deleting it.")
        }
        guard let summary = study.summaryJSON(examID: id).flatMap({ try? JSONSerialization.data(withJSONObject: $0) }),
              let taken = study.take(exam: id) else {
            return Self.failure(404, "exam_not_found", "That exam is not in the app.")
        }
        deleted.withLock { $0.append(Deleted(kind: .exam(taken, summary: summary), courseID: taken.courseID, at: now())) }
        return (204, [:])
    }

    private func undoExam(_ id: String) -> Reply {
        let found = deleted.withLock { list -> (Int, FakeStudy.Exam, Date)? in
            for (index, entry) in list.enumerated() {
                if case .exam(let exam, _) = entry.kind, exam.id == id { return (index, exam, entry.undoUntil) }
            }
            return nil
        }
        guard let (index, exam, undoUntil) = found else {
            return study.exam(id) != nil
                ? Self.failure(409, "not_deleted", "That exam is not deleted.")
                : Self.failure(404, "exam_not_found", "That exam is not in the app.")
        }
        if now() > undoUntil {
            return Self.failure(409, "undo_expired", "This exam was deleted more than \(Self.undoDays) days ago, so it can't be brought back.")
        }
        study.putBack(exam: exam)
        deleted.withLock { _ = $0.remove(at: index) }
        return (200, study.summaryJSON(examID: id) ?? [:])
    }

    // MARK: Recently deleted

    private func recentlyDeleted(_ courseID: String) -> Reply {
        let current = now()
        let list = deleted.withLock { list in
            list.filter { $0.courseID == courseID && current <= $0.undoUntil }.sorted { $0.at > $1.at }
        }
        var examPages: [[String: Any]] = []
        var folders: [[String: Any]] = []
        var sets: [[String: Any]] = []
        var exams: [[String: Any]] = []
        for entry in list {
            let window: [String: Any] = ["deletedAt": QBankJSON.formatDate(entry.at), "undoUntil": QBankJSON.formatDate(entry.undoUntil)]
            switch entry.kind {
            case .examPage(let page, let remembered):
                let back = study.foldersBack(remembered)
                examPages.append([
                    "id": page.id, "name": page.name, "folders": back.map { ["id": $0.id, "name": $0.name] },
                    "pastExamCount": study.pastExams(onPage: page.id, folderIDs: back.map(\.id)),
                    "undoRefusal": Self.json(pageUndoRefusal(page, undoUntil: entry.undoUntil)?.message),
                ].merging(window) { _, new in new })
            case .folder(let folder, let held):
                let clash = study.folders(courseID).first { $0.examPageID == folder.examPageID && $0.name.lowercased() == folder.name.lowercased() }
                let label = folder.examPageID.flatMap { page in
                    study.courseExamsJSON(courseID).first { $0["id"] as? String == page }?["name"] as? String
                } ?? FakeStudy.codes[courseID] ?? "This course"
                folders.append([
                    "id": folder.id, "name": folder.name, "examPageId": Self.json(folder.examPageID),
                    "sets": held.map { ["id": $0.id, "title": $0.title, "kind": $0.kind, "questionCount": $0.questionCount] },
                    "undoRefusal": Self.json(clash.map { "\(label) already has a folder named \($0.name). Rename one of them, then bring this one back." }),
                ].merging(window) { _, new in new })
            case .set(let id, let title, let folderID, let folderName, _, let questionCount):
                sets.append([
                    "id": id, "title": title, "kind": "practice", "folderId": folderID, "folderName": folderName, "questionCount": questionCount,
                    "undoRefusal": Self.json(setUndoRefusal(entry)?.message),
                ].merging(window) { _, new in new })
            case .examSet(let id, let title, let folderID, let folderName, let questionIDs):
                sets.append([
                    "id": id, "title": title, "kind": "exam", "folderId": folderID, "folderName": folderName, "questionCount": questionIDs.count,
                    "undoRefusal": Self.json(setUndoRefusal(entry)?.message),
                ].merging(window) { _, new in new })
            case .exam(_, let summary):
                let listed = (try? JSONSerialization.jsonObject(with: summary)) as? [String: Any] ?? [:]
                exams.append(listed.merging(window) { _, new in new })
            }
        }
        return (200, ["undoDays": Self.undoDays, "examPages": examPages, "folders": folders, "sets": sets, "exams": exams])
    }

    // MARK: Shared

    /// The sentence refusing to delete these questions' sets now: an exam in progress asks them.
    private func inUse(_ questionIDs: [String], courseID: String, name: String) -> String? {
        let ids = Set(questionIDs)
        guard study.runningExams(courseID: courseID).contains(where: { exam in exam.questions.contains { ids.contains($0.id) } }) else { return nil }
        return "An exam in progress asks questions from \(name). Finish or leave that exam first."
    }

    /// Her standing now and once it is deleted, as far as the fake counts it.
    private func standing(courseID: String, answered: Int, review: Int) -> [String: Any] {
        let reviewNow = study.reviewCount(courseID)
        let change = { (before: Int, after: Int) in ["before": before, "after": after] }
        return [
            "answeredCount": change(answered, 0), "fullyRightCount": change(0, 0), "reviewCount": change(reviewNow, max(0, reviewNow - review)),
            "points": change(0, 0), "maxPoints": change(0, 0), "wrongCount": change(0, 0),
        ]
    }

    private struct Refusal: Error {
        let status: Int
        let code: String
        let message: String

        init(_ status: Int, _ code: String, _ message: String) {
            self.status = status
            self.code = code
            self.message = message
        }

        var reply: Reply { FakeDeletions.failure(status, code, message) }
    }

    private static func reply(_ result: Result<[String: Any], Refusal>) -> Reply {
        switch result {
        case .success(let body): (200, body)
        case .failure(let refusal): refusal.reply
        }
    }

    private static func confirmed(_ confirm: String?, _ expected: String, name: String, unconfirmed: String? = nil) -> Refusal? {
        guard let confirm else {
            return Refusal(409, "confirmation_required", unconfirmed ?? "Look at what goes with \(name) and confirm it before deleting it.")
        }
        return confirm == expected ? nil : Refusal(409, "deletion_changed", "\(name) changed since you were warned. Look again before deleting it.")
    }

    /// A short fingerprint of what a delete would take, as the server's: 16 hex digits.
    private static func token(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: Words, as the server's `setMessage`, `folderMessage`, `pageMessage` and `examMessage`

    /// A preview's warning: its question and the rest, sent as `warning` and joined as `message`.
    struct Warning {
        let title: String
        let body: String

        init(_ sentences: [String]) {
            title = sentences.first ?? ""
            body = sentences.dropFirst().joined(separator: " ")
        }

        var message: String { "\(title) \(body)" }
        var json: [String: String] { ["title": title, "body": body] }
    }

    static func setWarning(
        title: String, folder: String, isExam: Bool, questionCount: Int, versionCount: Int, answeredCount: Int, reviewCount: Int, lastBank: Bool
    ) -> Warning {
        let go = questionCount == 1 ? "goes" : "go"
        var sentences: [String] = []
        if isExam {
            sentences.append("Delete \(title) from \(folder)'s exam bank?")
            sentences.append(lastBank
                ? "Its \(Wording.count(questionCount, "question")) \(go) with it, and exams over \(folder) go back to asking its practice questions."
                : "Its \(Wording.count(questionCount, "question")) \(go) with it, and exams over \(folder) stop asking \(questionCount == 1 ? "it" : "them").")
            if answeredCount > 0 {
                sentences.append("You have answered \(answeredCount) of them on exams: those answers stop counting toward Wrong questions.")
            }
        } else {
            sentences.append("Delete \(title)?")
            let earlier = versionCount - 1
            let versions = earlier > 0 ? ", and so \(earlier == 1 ? "does its earlier version" : "do its \(earlier) earlier versions")" : ""
            sentences.append("Its \(Wording.count(questionCount, "question")) \(go) with it\(versions).")
            if answeredCount > 0 {
                let review = reviewCount > 0 ? ", and \(Wording.count(reviewCount, "question")) \(reviewCount == 1 ? "leaves" : "leave") your Review list" : ""
                sentences.append("You have answered \(answeredCount) of them: those answers stop counting toward your progress\(review).")
            }
        }
        sentences.append("You can undo this for \(undoDays) days.")
        return Warning(sentences)
    }

    static func folderWarning(
        name: String, page: String?, titles: [String], questionCount: Int, answeredCount: Int, reviewCount: Int, pastExamCount: Int
    ) -> Warning {
        var sentences = ["Delete \(name)?"]
        if titles.isEmpty {
            sentences.append("It has no sets.")
        } else {
            let sets = titles.count == 1 ? "Its set goes" : "Its \(titles.count) sets go"
            sentences.append("\(sets) with it: \(FakeStudy.listText(titles)), \(Wording.count(questionCount, "question")) in all.")
            if answeredCount > 0 {
                let review = reviewCount > 0 ? ", and \(Wording.count(reviewCount, "question")) \(reviewCount == 1 ? "leaves" : "leave") your Review list" : ""
                sentences.append("You have answered \(answeredCount) of them: those answers stop counting toward your progress\(review).")
            }
        }
        if let page { sentences.append("It comes off \(page).") }
        if pastExamCount > 0 {
            sentences.append("Your \(Wording.count(pastExamCount, "past exam")) over it \(pastExamCount == 1 ? "stays" : "stay").")
        }
        sentences.append("You can undo this for \(undoDays) days.")
        return Warning(sentences)
    }

    static func pageWarning(name: String, folders: [String], pastExamCount: Int) -> Warning {
        var sentences = ["Delete \(name)?"]
        switch folders.count {
        case 0: sentences.append("It has no folders.")
        case 1: sentences.append("Its folder \(folders[0]) stays, with its sets and your progress, under Folders.")
        default: sentences.append("Its \(folders.count) folders stay, with their sets and your progress, under Folders: \(FakeStudy.listText(folders)).")
        }
        if pastExamCount > 0 {
            sentences.append("Your \(Wording.count(pastExamCount, "past exam")) over it \(pastExamCount == 1 ? "stays" : "stay").")
        }
        sentences.append("You can undo this for \(undoDays) days.")
        return Warning(sentences)
    }

    static func examWarning(answered: Int, changed: Int, unanswered: Int) -> Warning {
        var sentences = ["Delete this exam?"]
        if answered == 0 {
            sentences.append("You answered none of its questions, so your progress stays as it is.")
        } else {
            sentences.append("Your \(Wording.count(answered, "answer")) on it \(answered == 1 ? "goes" : "go") with it and \(answered == 1 ? "stops" : "stop") counting toward your progress.")
            var back: [String] = []
            if changed > 0 { back.append("\(Wording.count(changed, "question")) \(changed == 1 ? "goes" : "go") back to your answer before it") }
            if unanswered > 0 { back.append("\(Wording.count(unanswered, "question")) \(unanswered == 1 ? "goes" : "go") back to not answered") }
            if !back.isEmpty { sentences.append("\(back.joined(separator: ", and ")).") }
        }
        sentences.append("You can undo this for \(undoDays) days.")
        return Warning(sentences)
    }

    private static func json(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func failure(_ status: Int, _ code: String, _ message: String) -> Reply {
        (status, ["error": code, "message": message])
    }
}
#endif
