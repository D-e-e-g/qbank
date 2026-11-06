import Foundation
import Observation
import QBankKit

/// Import, as the web's Import screen does it: a question file from Files or pasted, checked by the
/// server's importer, then filed under a course or study topic and folder. The set goes to the course's Unsorted
/// folder unless she picks one; opened from a page, it starts on that page's course and folder (see
/// `SetDestination`), and a new folder named from an exam page goes on that page. A set whose name
/// the course already has asks first: replace it, or import it as a separate set.
@Observable
final class ImportModel {
    enum Source: Hashable {
        case file
        case paste
    }

    /// The set the import wrote, the exam page its folder is on, and the course or topic it went
    /// into, from her list read again, which has one the import made.
    struct Done: Equatable {
        let set: ImportedSet
        let examPageName: String?
        var course: CourseSummary?

        /// The course's code or the topic's name, which titles its screen until it loads.
        nonisolated var courseName: String {
            course.map(Wording.name) ?? set.courseCode
        }
    }

    var mode: Source = .file
    /// The file's text, pasted or read from the file she chose.
    private(set) var source = ""
    /// The file she chose, by name.
    private(set) var fileName: String?
    private(set) var report: ImportReport?
    /// The course and folder it goes into.
    let destination: SetDestination
    /// The set name: the file's title unless she changed it.
    private(set) var title = ""
    private(set) var titleEdited = false
    /// The course already has a set of this name: she chooses before anything is written.
    var conflict: ImportConflict?
    private(set) var done: Done?
    private(set) var problem: String?
    private(set) var isBusy = false
    /// The errors were copied for your agent.
    private(set) var copied = false

    private let app: AppModel

    init(app: AppModel, courseID: String? = nil, folderID: String? = nil, examPageID: String? = nil) {
        self.app = app
        destination = SetDestination(app: app, courseID: courseID, folderID: folderID, examPageID: examPageID, allowsNewCourse: true)
    }

    var isOnline: Bool {
        app.connection.isOnline
    }

    /// What the button does: Check file until the file is ready, then Import.
    var canImport: Bool {
        report?.ok == true
    }

    var canCheck: Bool {
        !isBusy && isOnline && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Her courses and their folders.
    func load() async {
        do {
            try await destination.load()
            problem = nil
        } catch {
            if app.handle(error) { return }
            // Without a connection the banner already says why nothing is here.
            problem = isOnline ? Wording.problem(error) : nil
        }
    }

    // MARK: Editing

    /// Text she typed or pasted. A new text needs a new check.
    func setSource(_ text: String) {
        guard text != source else { return }
        source = text
        report = nil
        copied = false
    }

    /// A file she picked in Files, read as text.
    func chooseFile(named name: String, text: String) {
        fileName = name
        problem = nil
        setSource(text)
    }

    /// A file that could not be read.
    func fileFailed(_ message: String) {
        problem = message
    }

    func setTitle(_ text: String) {
        title = text
        titleEdited = true
    }

    // MARK: Checking and importing

    func check() async {
        guard !app.frozen.refuses(), canCheck else { return }
        problem = nil
        copied = false
        isBusy = true
        defer { isBusy = false }
        do {
            let next = try await app.client.checkImport(source: source)
            report = next
            if !titleEdited, let fileTitle = next.title {
                title = fileTitle
            }
        } catch {
            report = nil
            if app.handle(error) { return }
            problem = Wording.problem(error) ?? "Could not check that file."
        }
    }

    /// Imports the checked file. A set of the same name is answered with `conflict`; she answers it
    /// with `replace` or `separate`.
    func commit(_ decision: ImportRequest.Decision = .import) async {
        guard !app.frozen.refuses(), let request = request(decision) else { return }
        // A new folder named from an exam page goes on that page once the set made it.
        let page = destination.folder == .new ? destination.examPageID : nil
        conflict = nil
        problem = nil
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await app.client.importSet(request) {
            case .conflict(let found):
                conflict = found
            case .imported(let set):
                var pageID = set.examPageID
                if pageID == nil, let page, (try? await app.client.placeFolder(id: set.folderID, onExamPage: page)) != nil {
                    pageID = page
                }
                // Done names the exam page the folder is on, read from the course it landed in.
                let landed = pageID == nil ? nil : try? await app.client.course(id: set.courseID)
                let catalog = try? await app.client.catalog()
                done = Done(set: set, examPageName: landed?.exams.first { $0.id == pageID }?.name, course: catalog?.course(id: set.courseID))
                saveForOffline(catalog)
            }
        } catch {
            if app.handle(error) { return }
            problem = Wording.problem(error) ?? "Could not import that file."
        }
    }

    /// What `commit` sends, or nil when a field it needs is empty, with the problem said.
    private func request(_ decision: ImportRequest.Decision) -> ImportRequest? {
        guard let folder = destination.importFolder else {
            problem = "Name the new folder, or pick one."
            return nil
        }
        let course: ImportRequest.Course
        if let id = destination.courseID {
            course = .existing(id: id)
        } else if destination.makesTopic {
            course = .newTopic(title: destination.newTopicName.trimmingCharacters(in: .whitespaces))
        } else {
            course = .new(
                code: destination.newCode.trimmingCharacters(in: .whitespaces),
                title: destination.newTitle.trimmingCharacters(in: .whitespaces),
                semesterNumber: destination.semesterNumber
            )
        }
        let name = title.trimmingCharacters(in: .whitespaces)
        return ImportRequest(source: source, title: name.isEmpty ? nil : name, course: course, folder: folder, decision: decision)
    }

    /// The new set is saved for offline at once, with the course list it belongs to.
    private func saveForOffline(_ catalog: Catalog?) {
        guard let offline = app.offline, let catalog else { return }
        offline.saveCourses(in: catalog, force: true)
    }

    /// The errors, one per line, for your agent to fix.
    func copyErrors() -> String {
        copied = true
        return report?.errors.joined(separator: "\n") ?? ""
    }

    /// "Import another file": the same course, and Unsorted unless she picks a folder.
    func startOver() async {
        guard let set = done?.set else { return }
        done = nil
        report = nil
        source = ""
        fileName = nil
        title = ""
        titleEdited = false
        await destination.restart(on: set.courseID)
    }
}

/// The words of Import's report, replace sheet and done screen, as the web says them.
nonisolated enum ImportWording {
    /// "Ready: 18 questions, 60 terms".
    static func ready(_ report: ImportReport) -> String {
        "Ready: \(Wording.count(report.questionCount, "question")), \(Wording.count(report.termCount, "term"))"
    }

    static let examNote = "An exam set: its questions are asked only on exams over its folder, never in practice or Review."

    static func replaceTitle(_ conflict: ImportConflict) -> String {
        "Replace “\(conflict.title)”?"
    }

    static func replaceMessage(_ conflict: ImportConflict) -> String {
        "\(Wording.name(code: conflict.courseCode, title: conflict.courseTitle)), \(conflict.folderName) already has a set with this name. Replacing swaps its \(conflict.existingQuestionCount) questions for the \(conflict.incomingQuestionCount) in this file, and it stays in \(conflict.folderName). Answers on unchanged questions are kept, and the old version stays restorable."
    }

    /// "“Title” · 18 questions in NURS 406, Week 3. It is on Exam 1." A topic is named by its name.
    static func doneCopy(_ done: ImportModel.Done) -> String {
        let set = done.set
        let noun = set.questionCount == 1 ? "question" : "questions"
        var copy = "“\(set.title)” · \(set.questionCount) \(set.setKind == .exam ? "exam " : "")\(noun) in \(done.courseName), \(set.folderName)."
        if let page = done.examPageName {
            copy += " It is on \(page)."
        } else if set.folderName == SetDestination.unsorted {
            copy += " It is in the \(Wording.words(done.course?.kind ?? .course).container)’s Folders list until you move it."
        }
        if set.setKind == .exam {
            copy += " Exams now ask them instead of that folder’s practice questions."
        }
        if set.kind == .replaced {
            copy += " The previous version can be restored from its folder."
        }
        return copy
    }
}
