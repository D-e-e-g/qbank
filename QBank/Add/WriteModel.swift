import Foundation
import Observation
import QBankKit

/// Writing a set by hand. The editor builds a question file from what she types and saves it through
/// Import, the path a pasted file takes, so the import check judges it in her course, topic or
/// account kind alike, and the editor says what it refused in her words. The set is filed where Import files it
/// (see `SetDestination`). What she has written is a draft kept on this phone until the set is saved.
@Observable
final class WriteModel {
    private(set) var draft: SetDraft
    /// Import's checking, filing and answers to a set of the same name, fed this draft's file.
    let importing: ImportModel
    /// The one thing the check cannot say: the set has no name yet.
    private(set) var titleProblem: String?
    /// Why an edit could not be saved as a new version of its set, when the check and the filing
    /// are not what went wrong.
    private(set) var editProblem: String?
    /// What became of the saved set since she opened it, when saving would no longer make a new
    /// version of the version she edited. Nothing is saved until she answers it.
    private(set) var outdated: Outdated?
    /// The set this edits is being read.
    private var isReading = false

    enum Outdated: Equatable {
        /// The set was deleted: she saves her questions as a new set, or discards them.
        case deleted
        /// The set was replaced or restored since: its current version became current at
        /// `activeSince`. She opens that version instead, or saves hers over it.
        case changed(activeSince: Date)
    }

    private let app: AppModel

    init(app: AppModel, draft: SetDraft = SetDraft()) {
        self.app = app
        self.draft = draft
        // A draft that edits a saved set files into that set's own course and folder.
        importing = ImportModel(app: app, courseID: draft.editing?.courseID, folderID: draft.editing?.folderID)
        importing.setSource(draft.file())
    }

    /// Whether this edits a saved set rather than writing a new one.
    var isEditing: Bool {
        draft.editing != nil
    }

    var isBusy: Bool {
        importing.isBusy || isReading
    }

    /// The check's answer for the draft as it stands. Nil before a check, and after any change.
    var report: ImportReport? {
        importing.report
    }

    /// Why the check refused the set, in the editor's words: each question by its number, and
    /// what to do in it. The check's own lines when it refused something else.
    var problems: [String] {
        guard let report, !report.ok else { return [] }
        let lines = draft.questions.enumerated().flatMap { index, question in
            question.problems.map { "Question \(index + 1): \($0)" }
        }
        return lines.isEmpty ? report.errors : lines
    }

    /// What the check refused in one question, shown with it.
    func problems(inQuestion id: UUID) -> [String] {
        guard let report, !report.ok else { return [] }
        return draft.questions.first { $0.id == id }?.problems ?? []
    }

    /// What she can fix: a problem with the course or the connection.
    var problem: String? {
        editProblem ?? importing.problem
    }

    var canSave: Bool {
        !isBusy && importing.isOnline
    }

    /// Changes the draft and keeps it on this phone. A changed draft needs a new check.
    /// Nothing changes while the set is being checked or filed, so what is filed is what she wrote.
    func edit(_ change: (inout SetDraft) -> Void) {
        guard !isBusy else { return }
        change(&draft)
        titleProblem = nil
        editProblem = nil
        importing.setSource(draft.file())
        app.drafts.keep(draft)
    }

    /// Changes one question of the draft.
    func editQuestion(id: UUID, _ change: (inout QuestionDraft) -> Void) {
        edit { draft in
            guard let index = draft.questions.firstIndex(where: { $0.id == id }) else { return }
            change(&draft.questions[index])
        }
    }

    func addQuestion() {
        edit { $0.questions.append(QuestionDraft()) }
    }

    func removeQuestion(id: UUID) {
        edit { draft in
            draft.questions.removeAll { $0.id == id }
            if draft.questions.isEmpty { draft.questions = [QuestionDraft()] }
        }
    }

    /// Checks the set with the import check and, when it passes, files it.
    func save() async {
        let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            titleProblem = "Give the set a name."
            return
        }
        guard canSave else { return }
        isReading = true
        let current = await checkEdited()
        isReading = false
        guard current else { return }
        importing.setTitle(name)
        await importing.check()
        guard importing.canImport else { return }
        await commit(.import)
        await replaceWhatIsEdited()
    }

    /// Files the checked set, as she answered when a set of the same name was there.
    func commit(_ decision: ImportRequest.Decision) async {
        importing.setTitle(draft.title.trimmingCharacters(in: .whitespacesAndNewlines))
        await importing.commit(decision)
        if importing.done != nil {
            app.drafts.discard(id: draft.id)
        }
    }

    /// An edit meets the set of its name, and only that set, with the import's replace: the same
    /// path the server takes, so the old version stays restorable and the questions she did not
    /// change keep their answers. Another set of the same name is never replaced: it is left alone
    /// and she is told.
    private func replaceWhatIsEdited() async {
        guard let edited = draft.editing, let conflict = importing.conflict else { return }
        importing.conflict = nil
        guard conflict.setID == edited.setID else {
            editProblem = WriteWording.otherSetNamed
            return
        }
        await commit(.replace)
    }

    /// Reads the set this draft edits as it is now, and says in `outdated` when it was deleted or
    /// has another version than the one she opened. True when saving makes a new version of the
    /// version she edited, and for a draft that edits no set.
    @discardableResult
    func checkEdited() async -> Bool {
        guard let edited = draft.editing else { return true }
        do {
            let course = try await app.client.course(id: edited.courseID)
            if let current = course.folders.flatMap(\.sets).first(where: { $0.id == edited.setID }) {
                outdated = current.activeSince == edited.activeSince ? nil : .changed(activeSince: current.activeSince)
            } else {
                outdated = .deleted
            }
            return outdated == nil
        } catch {
            if !app.handle(error) {
                editProblem = importing.isOnline ? Wording.problem(error) ?? "Could not read the set." : nil
            }
            return false
        }
    }

    /// The set she edited was deleted: her questions are saved as a new set, filed where it was.
    func saveAsNewSet() async {
        guard !isBusy, outdated == .deleted else { return }
        outdated = nil
        edit { $0.editing = nil }
        await save()
    }

    /// The set has another version than she opened: hers is saved over it as a new version.
    /// Restore in the folder brings the other one back.
    func saveAnyway() async {
        guard !isBusy, case .changed(let activeSince) = outdated else { return }
        outdated = nil
        edit { $0.editing?.activeSince = activeSince }
        await save()
    }

    /// The set has another version than she opened: her changes are discarded and the set is opened
    /// as it is now. A version the editor cannot keep whole is not opened, and her changes stay.
    func openCurrent() async {
        guard !isBusy, case .changed(let activeSince) = outdated, let edited = draft.editing else { return }
        isReading = true
        defer { isReading = false }
        do {
            let current = try await app.client.practiceSet(id: edited.setID)
            switch WriteEdit.draft(editing: current, folderID: edited.folderID, activeSince: activeSince) {
            case .success(var opened):
                opened.id = draft.id
                app.drafts.discard(id: draft.id)
                draft = opened
                outdated = nil
                editProblem = nil
                importing.setSource(draft.file())
            case .failure(let refusal):
                editProblem = refusal.message
            }
        } catch {
            if app.handle(error) { return }
            editProblem = Wording.problem(error) ?? "Could not open that set."
        }
    }

    /// Forgets the draft: she does not want the set.
    func discard() {
        app.drafts.discard(id: draft.id)
    }

    /// "Write another set": a new draft, in the course she wrote this one for.
    func startAnother() async {
        draft = SetDraft()
        titleProblem = nil
        outdated = nil
        await importing.startOver()
        importing.setSource(draft.file())
    }
}

/// The words of the editor.
nonisolated enum WriteWording {
    static let hint = "Write the question, word its choices and mark the right one. Saving checks the set as Import checks a file."
    static let titleHint = "What the set is called in its folder."
    static let draftNote = "Kept on this phone until you save it. Nothing is sent before then."
    static let editedTitleHint = "A saved set keeps its name."
    static let editHint = "Change the questions and save. Saving keeps the earlier version, and Restore in the folder brings it back. Questions you leave alone keep their answers."
    static let setChanged = "This set was replaced or restored after you opened it, so its current version is not the one you changed. Your changes are kept here."
    static let setDeleted = "This set was deleted after you opened it. Your changes are kept here."
    static let otherSetNamed = "Another set has this name, so nothing was saved. Your changes are kept here."
    static let editNote = "Your changes are kept on this phone until you save them. The saved set stays as it is until then."

    /// "3 questions", or "No questions yet", for a draft's row.
    static func detail(_ draft: SetDraft) -> String {
        let written = draft.questions.filter { !$0.isBlank }.count
        let count = written == 0 ? "No questions yet" : Wording.count(written, "question")
        return draft.editing == nil ? count : "Changes to a saved set · \(count)"
    }

    static func name(_ draft: SetDraft) -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled set" : title
    }
}
