import Foundation
import Observation
import QBankKit

/// Writing a set by hand. The editor builds a question file from what she types and saves it through
/// Import, the path a pasted file takes, so the import check judges it in her course, topic or
/// account kind alike and says what to fix in its own words. The set is filed where Import files it
/// (see `SetDestination`). What she has written is a draft kept on this phone until the set is saved.
@Observable
final class WriteModel {
    private(set) var draft: SetDraft
    /// Import's checking, filing and answers to a set of the same name, fed this draft's file.
    let importing: ImportModel
    /// The one thing the check cannot say: the set has no name yet.
    private(set) var titleProblem: String?

    private let app: AppModel

    init(app: AppModel, draft: SetDraft = SetDraft()) {
        self.app = app
        self.draft = draft
        importing = ImportModel(app: app)
        importing.setSource(draft.file())
    }

    var isBusy: Bool {
        importing.isBusy
    }

    /// The check's errors, which block saving, and its warnings, in the importer's words.
    var report: ImportReport? {
        importing.report
    }

    /// What she can fix: the check's errors, or a problem with the course or the connection.
    var problem: String? {
        importing.problem
    }

    var canSave: Bool {
        !isBusy && importing.isOnline
    }

    /// Changes the draft and keeps it on this phone. A changed draft needs a new check.
    func edit(_ change: (inout SetDraft) -> Void) {
        change(&draft)
        titleProblem = nil
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
        importing.setTitle(name)
        await importing.check()
        guard importing.canImport else { return }
        await commit(.import)
    }

    /// Files the checked set, as she answered when a set of the same name was there.
    func commit(_ decision: ImportRequest.Decision) async {
        importing.setTitle(draft.title.trimmingCharacters(in: .whitespacesAndNewlines))
        await importing.commit(decision)
        if importing.done != nil {
            app.drafts.discard(id: draft.id)
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
        await importing.startOver()
        importing.setSource(draft.file())
    }
}

/// The words of the editor.
nonisolated enum WriteWording {
    static let hint = "Write the question, word its choices and mark the right one. Saving checks the set as Import checks a file."
    static let titleHint = "What the set is called in its folder."
    static let draftNote = "Kept on this phone until you save it. Nothing is sent before then."

    /// "3 questions", for a draft's row.
    static func detail(_ draft: SetDraft) -> String {
        let written = draft.questions.filter { !$0.isBlank }.count
        return Wording.count(max(written, 1), "question")
    }

    static func name(_ draft: SetDraft) -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled set" : title
    }
}
