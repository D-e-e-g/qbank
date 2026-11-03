import Foundation
import Observation
import QBankKit

/// One course or study topic: its score line, the Exam, Review and Terms tiles, its pages and its
/// folders. The course page, one of its pages and a folder share one model, so an edit on one shows on all.
/// Without a connection it shows the copy saved on the phone, with her waiting answers counted in.
@Observable
final class CourseModel {
    /// Where a set goes when she moves it: one of the course's folders, or a new one by name.
    enum Destination: Equatable {
        case folder(String)
        case newFolder(String)
    }

    /// Which exam page a folder goes on.
    enum PageChoice: Hashable {
        case page(String)
        case none
        /// A new page, named `name`, holding only this folder.
        case new(name: String)
    }

    let id: String
    private(set) var course: CourseDetail?
    /// Her exams in this course, for the exam pages: the running one first, then newest first.
    private(set) var sittings: [ExamSummary] = []
    /// The server's plan for an exam over each exam page's folders, by page id, for its Start exam line.
    private(set) var pagePlans: [String: ExamPreview] = [:]
    private(set) var isLoading = false
    private(set) var problem: String?
    private(set) var isRestoring = false
    /// Whether the server lets her make questions, for the +'s Make questions. Nil until read.
    private(set) var maker: QuestionMakerStatus?
    /// When the course on screen was saved on the phone, or nil when it came from QBank just now.
    private(set) var savedAt: Date?
    /// Counts loads, so an answer that comes back after a newer load started is dropped: a
    /// refresh read before an edit must not put the old names back.
    private var loads = 0

    private let app: AppModel

    init(app: AppModel, id: String) {
        self.app = app
        self.id = id
    }

    /// A student's course is remembered as her study place, so the next launch opens it.
    var remembersPlace: Bool {
        app.account?.role == .student
    }

    var isStudent: Bool {
        app.account?.role == .student
    }

    /// Folders and exam pages change on the server, so without a connection they cannot be edited.
    var canEdit: Bool {
        app.connection.isOnline && savedAt == nil
    }

    /// The +'s Make questions shows only when the server says she may start a set now, as the Add
    /// tab's row does.
    var canMake: Bool {
        isStudent && canEdit && maker?.available == true
    }

    /// Reads whether she may make questions. Failing leaves Make questions off the +.
    func loadMaker() async {
        guard isStudent, app.connection.isOnline else { return }
        maker = try? await app.client.questionMakerStatus()
    }

    /// The course as the study screens name it.
    var ref: CourseRef? {
        course.map { CourseRef(id: $0.id, code: $0.code, title: $0.title, kind: $0.kind) }
    }

    /// The words its screens say: a topic's say topic. A course's until it loads.
    var words: KindWords {
        Wording.words(course?.kind ?? .course)
    }

    var layout: CourseLayout? {
        course.map { CourseLayout(course: $0, sittings: sittings) }
    }

    func folder(_ id: String) -> Folder? {
        course?.folders.first { $0.id == id }
    }

    /// The exam page a folder is on, or nil.
    func page(of folder: Folder) -> CourseExam? {
        course?.exams.first { $0.id == folder.examPageID }
    }

    /// Loads the course, her exams in it, and the plan for each exam page. A failed reload keeps
    /// what is already on screen. Her exams and the plans are only for the exam pages and come from
    /// QBank, so failing to read them, or having no connection, leaves the course usable with the
    /// ones it showed last.
    func load() async {
        loads += 1
        let load = loads
        isLoading = true
        defer {
            if load == loads { isLoading = false }
        }
        async let setup = sittingsSetup()
        do {
            let loaded = try await app.load(.course(id)) { () async throws(QBankError) in try await app.client.course(id: id) }
            let counted = await counted(loaded.value)
            guard load == loads else {
                _ = await setup
                return
            }
            course = counted
            savedAt = loaded.savedAt
            problem = nil
        } catch {
            _ = await setup
            if load == loads { report(error) }
            return
        }
        if let setup = await setup, load == loads {
            sittings = (setup.inProgress.map { [$0] } ?? []) + setup.exams
            pagePlans = Dictionary(setup.courseExams.map { ($0.courseExamID, $0.preview) }) { first, _ in first }
        }
    }

    private func sittingsSetup() async -> ExamSetup? {
        guard app.connection.isOnline else { return nil }
        return try? await app.client.examSetup(courseID: id)
    }

    /// The course with the answers waiting on the phone counted in.
    private func counted(_ course: CourseDetail) async -> CourseDetail {
        guard let offline = app.offline, !offline.waiting.isEmpty else { return course }
        return await offline.waitingProgress().counting(course)
    }

    /// Remembers this course as the one she used last. Failing is harmless: the next open tries again.
    func rememberPlace() async {
        guard remembersPlace, app.connection.isOnline else { return }
        try? await app.client.setStudyPlace(courseID: id)
    }

    /// Brings back the previous version of a set she confirmed, then reloads the course.
    func restore(_ set: PracticeSetSummary) async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await app.client.restorePracticeSet(id: set.id)
            problem = nil
        } catch {
            report(error)
            return
        }
        await load()
    }

    /// What an exam over an exam page's folders draws, as the server last said. Nil before it said.
    func plan(for page: ExamPage) -> ExamPreview? {
        pagePlans[page.id]
    }

    /// Exam setup with an exam page's folders ticked, from its Start exam button.
    func examSetup(for page: ExamPage) -> ExamSetupRoute? {
        ref.map { ExamSetupRoute(course: $0, folderIDs: page.folders.map(\.id), examName: page.exam.name) }
    }

    // MARK: Editing her folders

    /// The next free page name: Page 1, Page 2, ...
    var nextPageName: String {
        Wording.nextPageName(after: course?.exams.map(\.name) ?? [])
    }

    /// Makes an empty folder, under Folders, or with `page` on that exam page, at the end of its
    /// folders. Returns what went wrong in her words, or nil once it is saved. Refused on the page,
    /// it stays under Folders.
    func makeFolder(named name: String, on page: String?) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await edit { () async throws(QBankError) in
            let folder = try await app.client.createFolder(courseID: id, name: name)
            if let page {
                try await app.client.placeFolder(id: folder.id, onExamPage: page)
            }
        }
    }

    /// Renames a folder. Returns what went wrong in her words, or nil once it is saved.
    func rename(_ folder: Folder, to name: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != folder.name else { return nil }
        return await edit { () async throws(QBankError) in
            try await app.client.renameFolder(id: folder.id, name: name)
        }
    }

    /// Puts a folder on an exam page, at the end of its folders, on none, or on a new page of its
    /// own. Its sets and progress stay in the folder.
    func put(_ folder: Folder, on choice: PageChoice) async -> String? {
        guard let course else { return nil }
        switch choice {
        case .page(let id):
            guard id != folder.examPageID else { return nil }
            return await edit { () async throws(QBankError) in
                try await app.client.placeFolder(id: folder.id, onExamPage: id)
            }
        case .none:
            guard folder.examPageID != nil else { return nil }
            return await edit { () async throws(QBankError) in
                try await app.client.placeFolder(id: folder.id, onExamPage: nil)
            }
        case .new(let name):
            return await edit { () async throws(QBankError) in
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if folder.examPageID == nil {
                    _ = try await app.client.createCourseExam(courseID: course.id, name: name, folderIDs: [folder.id])
                } else {
                    // A page cannot be made holding another page's folder, so the folder moves
                    // onto it once it exists.
                    let page = try await app.client.createCourseExam(courseID: course.id, name: name, folderIDs: [])
                    try await app.client.placeFolder(id: folder.id, onExamPage: page.id)
                }
            }
        }
    }

    /// Moves sets into another folder, or into a new one made on no exam page. Her answers and
    /// progress move with each set. A set moved before a refusal stays moved; once the new folder
    /// is made, `destination` becomes that folder, so trying again moves the rest into it.
    func move(_ sets: [PracticeSetSummary], to destination: inout Destination) async -> String? {
        guard !sets.isEmpty else { return nil }
        return await edit { () async throws(QBankError) in
            var rest = sets[...]
            let folderID: String
            switch destination {
            case .folder(let id):
                folderID = id
            case .newFolder(let name):
                // The first set makes the new folder, so a refused name leaves no empty folder behind.
                let first = rest.removeFirst()
                folderID = try await app.client.moveSet(id: first.id, toNewFolder: name.trimmingCharacters(in: .whitespacesAndNewlines)).id
                destination = .folder(folderID)
            }
            for set in rest {
                try await app.client.moveSet(id: set.id, toFolder: folderID)
            }
        }
    }

    /// Saves her order of one list: an exam page's folders, or the folders on no exam page.
    func saveOrder(page: String?, folderIDs: [String]) async -> String? {
        await edit { () async throws(QBankError) in
            try await app.client.setFolderOrder(courseID: id, examPageID: page, folderIDs: folderIDs)
        }
    }

    /// Runs one edit, then reads the course again, whether or not every step was saved.
    private func edit(_ change: () async throws(QBankError) -> Void) async -> String? {
        var failure: String?
        do {
            try await change()
        } catch {
            failure = app.handle(error) ? nil : Wording.problem(error) ?? "Something went wrong. Try again."
        }
        await load()
        return failure
    }

    private func report(_ error: QBankError) {
        guard !app.handle(error), let words = Wording.problem(error) else { return }
        problem = words
    }
}
