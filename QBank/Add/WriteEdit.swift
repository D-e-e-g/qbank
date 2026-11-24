import Foundation
import QBankKit

/// Opening a saved set in the set editor. A set can be opened when the editor can write back every
/// part of every question exactly as it is: then a question she did not touch is saved word for
/// word, keeps its id and so keeps the answers given to it. A set with any part the editor cannot
/// keep is not opened, and the reason is said in her words, so saving never drops a picture, a table
/// or a note she cannot see here.
nonisolated enum WriteEdit {
    static let examSet = "This is an exam set. Its questions are written in a question file, not here."
    static let unsupported = "This set has a part the editor cannot keep yet, such as a picture, a table, a term, a step note or a format other than single answer, select all and true or false. It is left as it is."
    static let missing = "This set is no longer in its course."

    /// The set's row in `course`, which says which version of it is current: its `activeSince`.
    static func row(of setID: String, in course: CourseDetail) -> PracticeSetSummary? {
        course.folders.flatMap(\.sets).first { $0.id == setID }
    }

    /// Reads the set with this id as it is now and opens it, or says why it cannot be opened. Its
    /// row is read before its questions, so the version the draft records is never newer than the
    /// questions it holds.
    static func open(setID: String, courseID: String, folderID: String, client: QBankClient) async throws(QBankError) -> Result<SetDraft, Refusal> {
        guard let row = row(of: setID, in: try await client.course(id: courseID)) else { return .failure(Refusal(message: missing)) }
        return draft(editing: try await client.practiceSet(id: setID), folderID: folderID, activeSince: row.activeSince)
    }

    /// The draft that edits `set`, or why it cannot be opened. The draft takes the set's name, which
    /// stays the same: saving replaces the set of that name with a new version. `activeSince` is the
    /// set row's, which says which version of the set this is.
    static func draft(editing set: PracticeSet, folderID: String, activeSince: Date) -> Result<SetDraft, Refusal> {
        guard set.kind == .practice else { return .failure(Refusal(message: examSet)) }
        var questions: [QuestionDraft] = []
        for question in set.questions {
            guard let written = QuestionDraft(saved: question) else { return .failure(Refusal(message: unsupported)) }
            questions.append(written)
        }
        guard !questions.isEmpty else { return .failure(Refusal(message: unsupported)) }
        var draft = SetDraft(title: set.title)
        draft.questions = questions
        draft.editing = EditedSet(setID: set.id, courseID: set.courseID, folderID: folderID, activeSince: activeSince)
        return .success(draft)
    }

    struct Refusal: Error, Equatable {
        let message: String
    }
}

nonisolated extension QuestionDraft {
    /// A saved question as the editor writes it, or nil when it has anything the editor would not
    /// write back unchanged: a stem, a topic, a takeaway, terms, a table, images, a note on a choice,
    /// a format it does not write, or fields it does not know.
    init?(saved question: Question) {
        guard question.stem.isEmpty, question.topic.isEmpty, question.takeaway.isEmpty, question.clinicalJudgmentStep == nil,
            question.terms.isEmpty, question.weekLabel == nil,
            case .object(let body) = question.rawBody, Set(body.keys) == ["options"],
            let options = question.rawBody["options"]?.arrayValue, options.count >= 2
        else { return nil }
        var texts: [String] = []
        var right: Set<Int> = []
        for (position, option) in options.enumerated() {
            guard case .object(let fields) = option, let text = option["t"]?.stringValue else { return nil }
            switch Set(fields.keys) {
            case ["t"]: break
            case ["t", "ok"] where option["ok"] == .bool(true): right.insert(position)
            default: return nil
            }
            // Text the editor would trim or drop is text it would not write back as it was.
            guard text == text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            texts.append(text)
        }
        guard question.ask == question.ask.trimmingCharacters(in: .whitespacesAndNewlines),
            question.rationale == question.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        self.init()
        fileID = question.publicID
        ask = question.ask
        explanation = question.rationale
        switch question.type {
        case .single where texts == Self.trueFalseChoices && right.count == 1:
            kind = .trueFalse
            rightTrueFalse = right.first
        case .single where right.count == 1 && texts.count <= Self.choiceRange.upperBound:
            kind = .single
            choices = texts.map { Choice(text: $0) }
            rightChoice = right.first
        case .sata where !right.isEmpty && texts.count <= Self.choiceRange.upperBound:
            kind = .selectAll
            choices = texts.map { Choice(text: $0) }
            rightChoices = right
        default:
            return nil
        }
    }
}
