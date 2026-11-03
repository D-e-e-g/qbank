import Foundation
import QBankKit

/// How far she is through a folder's practice sets, as the web counts it
/// (`apps/web/src/course/folders.ts`).
nonisolated struct FolderProgress: Equatable {
    /// Nothing answered, some, or every question.
    enum State: Equatable {
        case fresh
        case started
        case done
    }

    let state: State
    let setCount: Int
    let questionCount: Int
    let answeredCount: Int
    let fullyRightCount: Int

    init(_ folder: Folder) {
        self.init(sets: folder.sets)
    }

    init(sets: [PracticeSetSummary]) {
        setCount = sets.count
        questionCount = sets.reduce(0) { $0 + $1.questionCount }
        answeredCount = sets.reduce(0) { $0 + min($1.answeredCount, $1.questionCount) }
        fullyRightCount = sets.reduce(0) { $0 + min($1.fullyRightCount, $1.questionCount) }
        state = answeredCount == 0 ? .fresh : answeredCount >= questionCount ? .done : .started
    }
}

/// The lines the course's lists, an exam page and a folder show, worded as on the web.
nonisolated enum FolderWording {
    /// A folder's line: "2 sets · 27 questions", "2 sets · 22 of 27 answered",
    /// "2 sets · 22 of 27 fully right", "Exam twins only · 17 questions", or "Empty folder".
    static func meta(_ folder: Folder) -> String {
        let progress = FolderProgress(folder)
        if progress.setCount == 0 {
            return folder.examBankCount > 0 ? "Exam twins only · \(Wording.count(folder.examBankCount, "question"))" : "Empty folder"
        }
        let sets = Wording.count(progress.setCount, "set")
        switch progress.state {
        case .fresh: return "\(sets) · \(Wording.count(progress.questionCount, "question"))"
        case .done: return "\(sets) · \(progress.fullyRightCount) of \(progress.questionCount) fully right"
        case .started: return "\(sets) · \(progress.answeredCount) of \(progress.questionCount) answered"
        }
    }

    /// The word at a row's right edge: Done, how far she is, or Not started. Empty without practice sets.
    static func state(_ progress: FolderProgress) -> String {
        guard progress.setCount > 0 else { return "" }
        switch progress.state {
        case .done: return "Done"
        case .fresh: return "Not started"
        case .started: return "\(progress.answeredCount) of \(progress.questionCount)"
        }
    }

    /// The exam line under a folder's sets: "Exam twins: 27 questions, exams only", or that its exams
    /// use practice questions.
    static func examBank(_ folder: Folder) -> String {
        folder.examBankCount > 0
            ? "Exam twins: \(Wording.count(folder.examBankCount, "question")), exams only"
            : "No exam bank yet · exams use practice questions"
    }

    /// The line under the folder's name on its own screen: "On Exam 2 · 3 sets · 36 of 45 fully
    /// right", or "On no page · ...".
    static func folderNote(_ folder: Folder, page: CourseExam?) -> String {
        "\(page.map { "On \($0.name)" } ?? "On no page") · \(meta(folder))"
    }

    /// An exam page's row on the course page: "5 folders · 217 questions", or "No folders yet".
    static func pageRow(_ page: ExamPage) -> String {
        guard !page.folders.isEmpty else { return "No folders yet" }
        return "\(Wording.count(page.folders.count, "folder")) · \(Wording.count(page.progress.questionCount, "question"))"
    }

    /// The line under an exam page's name: "5 folders · 16 practice sets · 217 questions", or
    /// "No folders yet". Folder rows keep "2 sets".
    static func pageNote(_ page: ExamPage) -> String {
        guard !page.folders.isEmpty else { return "No folders yet" }
        return [
            Wording.count(page.folders.count, "folder"),
            Wording.count(page.progress.setCount, "practice set"),
            Wording.count(page.progress.questionCount, "question"),
        ].joined(separator: " · ")
    }

    /// Under Start exam, beside the draw line, when a folder on the page has exam twins:
    /// "Exam twins: 14 in Week 5 · exams draw from these first", or for several folders
    /// "Exam twins: 41 in Week 4, Week 5 and Week 6 · exams draw from these first". Nil when none do.
    static func examTwins(_ page: ExamPage) -> String? {
        let banks = page.folders.filter { $0.examBankCount > 0 }
        guard !banks.isEmpty else { return nil }
        let count = banks.reduce(0) { $0 + $1.examBankCount }
        return "Exam twins: \(count) in \(listed(banks.map(\.name))) · exams draw from these first"
    }

    /// "Week 5", "Week 4 and Week 5", "Week 4, Week 5 and Week 6", in the order given.
    private static func listed(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.joined() }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// Under an exam page's Start exam, from the server's plan over its folders: "40 questions from
    /// the 217 in these 5 folders, or Wrong questions only.", or "All 26 questions in this folder,
    /// ...". Nil when its folders hold none.
    static func examDraw(_ plan: ExamPreview) -> String? {
        let folders = plan.folders
        guard !folders.isEmpty else { return nil }
        let total = folders.reduce(0) { $0 + $1.questionCount }
        let place = folders.count == 1 ? "this folder" : "these \(folders.count) folders"
        let draw = plan.questionCount < total
            ? "\(Wording.count(plan.questionCount, "question")) from the \(total) in \(place)"
            : "All \(Wording.count(total, "question")) in \(place)"
        return "\(draw), or Wrong questions only."
    }
}

extension Folder {
    /// How many questions an exam over this folder draws from: its exam bank, or its practice
    /// questions when it has none.
    nonisolated var examQuestionCount: Int {
        examBankCount > 0 ? examBankCount : sets.reduce(0) { $0 + $1.questionCount }
    }
}

/// An exam page with its folders and the exams she took over them.
nonisolated struct ExamPage: Equatable, Identifiable {
    let exam: CourseExam
    /// Its folders, in her order.
    let folders: [Folder]
    /// Her exams over these folders, the running one first, then newest first.
    let sittings: [ExamSummary]
    let progress: FolderProgress

    var id: String { exam.id }

    var examQuestionCount: Int {
        folders.reduce(0) { $0 + $1.examQuestionCount }
    }
}

/// The course as its page lists it: the exam pages, each with its own folders, and the folders on
/// no exam page.
/// The course page's two lists, in the order the server sends them: exam pages in the order they
/// were added, each with its folders in her order, then the folders on no exam page in her order.
nonisolated struct CourseLayout: Equatable {
    let pages: [ExamPage]
    /// The folders on no exam page, in her order.
    let looseFolders: [Folder]

    /// - Parameter sittings: Her exams, the running one first, then newest first.
    init(course: CourseDetail, sittings: [ExamSummary]) {
        let ids = Set(course.exams.map(\.id))
        pages = course.exams.map { exam in
            let folders = course.folders.filter { $0.examPageID == exam.id }
            return ExamPage(
                exam: exam,
                folders: folders,
                sittings: sittings.filter { Self.page(of: $0, in: course) == exam.id },
                progress: FolderProgress(sets: folders.flatMap(\.sets))
            )
        }
        looseFolders = course.folders.filter { $0.examPageID.map { !ids.contains($0) } ?? true }
    }

    func page(_ id: String) -> ExamPage? {
        pages.first { $0.id == id }
    }

    /// The exam page a sitting belongs to: the one holding every folder it covered, as the server
    /// rules (`courseExamOf`). The server's answer is kept while that page still holds them; the rule
    /// itself covers a sitting read before the pages changed. A sitting from before folders is
    /// matched by its folder names.
    static func page(of sitting: ExamSummary, in course: CourseDetail) -> String? {
        let holds = { (exam: CourseExam) -> Bool in
            let folders = course.folders.filter { $0.examPageID == exam.id }
            if let ids = sitting.folderIDs {
                return !ids.isEmpty && ids.allSatisfy { id in folders.contains { $0.id == id } }
            }
            return !sitting.weeks.isEmpty && sitting.weeks.allSatisfy { name in folders.contains { $0.name == name } }
        }
        if let id = sitting.courseExamID, let exam = course.exams.first(where: { $0.id == id }), holds(exam) { return id }
        return course.exams.first(where: holds)?.id
    }
}
