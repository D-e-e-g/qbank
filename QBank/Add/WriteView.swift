import QBankDesign
import QBankKit
import SwiftUI

/// The set editor: a set name, questions with their choices, and where the set goes. Save checks
/// the set with the import check, says what it refused in the editor's words, and files it the way
/// Import does. What
/// she has written stays on this phone as a draft until it is saved or discarded.
struct WriteView: View {
    let app: AppModel
    @State private var model: WriteModel
    /// Opens the folder the set went into.
    let openFolder: (ImportModel.Done) -> Void
    @State private var asksToDiscard = false
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case title
        case destination(DestinationField)
    }

    init(app: AppModel, draft: SetDraft = SetDraft(), openFolder: @escaping (ImportModel.Done) -> Void) {
        self.app = app
        self.openFolder = openFolder
        _model = State(initialValue: WriteModel(app: app, draft: draft))
    }

    var body: some View {
        ScrollView {
            Group {
                if let done = model.importing.done {
                    DoneView(done: done, addedTitle: "Saved", anotherTitle: "Write another set") {
                        openFolder(done)
                    } another: {
                        Task { await model.startAnother() }
                    }
                } else {
                    form
                }
            }
            .screenColumn()
            .padding(.top, QBankSpacing.space2)
            .padding(.bottom, QBankSpacing.space7)
        }
        .scrollDismissesKeyboard(.interactively)
        .qbankScreenBackground()
        .navigationTitle(model.isEditing ? "Edit questions" : "Write questions")
        .screenColumnTitle()
        .task { await model.importing.load() }
        .sheet(item: Binding(get: { model.isEditing ? nil : model.importing.conflict }, set: { model.importing.conflict = $0 })) { conflict in
            ReplaceSheet(conflict: conflict) { decision in
                model.importing.conflict = nil
                guard let decision else { return }
                Task { await model.commit(decision) }
            }
        }
        .confirmSheet(
            isPresented: $asksToDiscard,
            title: model.isEditing ? "Discard these changes?" : "Discard this draft?",
            message: model.isEditing
                ? "Your changes are deleted from this phone. The saved set stays as it is."
                : "The questions you wrote here are deleted from this phone.",
            confirm: model.isEditing ? "Discard changes" : "Discard draft",
            identifier: "write.discard.sheet"
        ) {
            model.discard()
            dismiss()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space5) {
            if !model.importing.isOnline {
                OfflineBanner(title: "Saving needs a connection", message: "QBank checks the set and files it on the server. Your draft is kept on this phone.")
                    .accessibilityIdentifier("write.offline")
            }
            Text(model.isEditing ? WriteWording.editHint : WriteWording.hint)
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .padding(.horizontal, QBankSpacing.space1)
            Group {
                if model.isEditing {
                    // The name finds the set to replace, so it stays as it is.
                    LabeledField(label: "Set name", hint: WriteWording.editedTitleHint) {
                        Text(model.draft.title)
                            .qbankFont(.body)
                            .foregroundStyle(.qbank(.text2))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("write.title")
                    }
                } else {
                    LabeledField(label: "Set name", hint: WriteWording.titleHint) {
                        TextField("Set name", text: Binding(get: { model.draft.title }, set: { text in model.edit { $0.title = text } }))
                            .focused($focus, equals: .title)
                            .submitLabel(.done)
                            .accessibilityIdentifier("write.title")
                    }
                }
                if let problem = model.titleProblem {
                    ProblemText(text: problem)
                        .accessibilityIdentifier("write.titleProblem")
                }
                ForEach(Array(model.draft.questions.enumerated()), id: \.element.id) { index, question in
                    WriteQuestionEditor(
                        number: index + 1,
                        question: question,
                        problems: model.problems(inQuestion: question.id),
                        canRemove: model.draft.questions.count > 1
                    ) { change in
                        model.editQuestion(id: question.id, change)
                    } remove: {
                        model.removeQuestion(id: question.id)
                    }
                }
                Button {
                    model.addQuestion()
                } label: {
                    Label("Add a question", systemImage: "plus")
                }
                .buttonStyle(.qbank(.secondary, size: .large, fullWidth: true))
                .accessibilityIdentifier("write.add")
            }
            .disabled(model.isBusy)
            if !model.isEditing {
                DestinationFields(destination: model.importing.destination, focus: $focus, field: Field.destination)
            }
            if !model.problems.isEmpty {
                Issues(items: model.problems)
                    .padding(QBankSpacing.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.qbank(.wrongSoft), in: .rect(cornerRadius: QBankRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous).strokeBorder(.qbank(.wrongBorder), lineWidth: QBankBorder.regular))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("write.errors")
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            Button {
                focus = nil
                Task { await model.save() }
            } label: {
                ButtonLabel(text: model.isEditing ? "Save new version" : "Save set", isBusy: model.isBusy)
            }
            .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
            .disabled(!model.canSave)
            .answersWhenFrozen(app.frozen)
            .accessibilityIdentifier("write.save")
            FieldHint(model.isEditing ? WriteWording.editNote : WriteWording.draftNote)
            Button(model.isEditing ? "Discard changes" : "Discard draft") { asksToDiscard = true }
                .buttonStyle(.qbank(.quiet, size: .large, fullWidth: true))
                .disabled(model.isBusy)
                .accessibilityIdentifier("write.discard")
        }
    }
}
