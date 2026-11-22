import QBankDesign
import QBankKit
import SwiftUI

/// A sheet over a folder or exam page with Cancel, its title, and the button that saves, as the
/// web's sheets set them. While it saves, the button turns into a spinner and the sheet stays.
struct EditSheet<Content: View>: View {
    let title: String
    let confirm: String
    let identifier: String
    let isSaving: Bool
    var hasChanges = true
    let save: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                    content
                }
                .padding(.horizontal, QBankSpacing.gutterPhone)
                .padding(.top, QBankSpacing.space2)
                .padding(.bottom, QBankSpacing.space7)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(.qbank(.bg), ignoresSafeAreaEdges: .all)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("\(identifier).cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(confirm, action: save)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("\(identifier).save")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving || hasChanges)
        .accessibilityIdentifier(identifier)
    }
}

/// A hint under a sheet's fields.
struct SheetHint: View {
    let text: String

    var body: some View {
        Text(text)
            .qbankFont(.footnote)
            .foregroundStyle(.qbank(.text3))
            .padding(.horizontal, QBankSpacing.space1)
    }
}

/// A choice in a sheet's list: its name, a line under it, and a checkmark when it is picked.
struct ChoiceRow: View {
    let title: String
    var detail: String?
    let isPicked: Bool
    var isEnabled = true
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            QBankListRow(title, detail: detail, isSelected: isPicked) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.qbank(.tint))
                    .opacity(isPicked ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.qbankRow)
        .disabled(!isEnabled)
    }
}

/// Rename folder: one field. Only the name changes.
struct RenameFolderSheet: View {
    let model: CourseModel
    let folder: Folder
    @State private var name: String
    @State private var problem: String?
    @State private var isSaving = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: CourseModel, folder: Folder) {
        self.model = model
        self.folder = folder
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        EditSheet(title: "Rename folder", confirm: "Save", identifier: "renameFolder", isSaving: isSaving, hasChanges: name != folder.name, save: save) {
            LabeledField(label: "Folder name") {
                TextField("Folder name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier("renameFolder.name")
            }
            if let problem {
                ProblemText(text: problem)
            }
            SheetHint(text: "Only the name changes. Its sets, their progress, its page and your past exams stay with it.")
        }
        .onAppear { focused = true }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !isSaving else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "Folder name is required."
            return
        }
        isSaving = true
        Task {
            problem = await model.rename(folder, to: name)
            isSaving = false
            if problem == nil { dismiss() }
        }
    }
}

/// Page: which page a folder is on, none, or a new one. Its sets and
/// progress stay put.
struct ExamPageSheet: View {
    let model: CourseModel
    let folder: Folder
    @State private var choice: CourseModel.PageChoice
    @State private var problem: String?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: CourseModel, folder: Folder) {
        self.model = model
        self.folder = folder
        _choice = State(initialValue: folder.examPageID.map { .page($0) } ?? .none)
    }

    var body: some View {
        let pages = model.layout?.pages ?? []
        let newName = model.nextPageName
        let words = model.words
        EditSheet(title: "Page", confirm: "Done", identifier: "examPage", isSaving: isSaving, hasChanges: choice != current, save: save) {
            SheetHint(text: "\(folder.name) can be on one page. Its sets and progress stay in the folder.")
            if let problem {
                ProblemText(text: problem)
            }
            QBankListGroup {
                ForEach(pages) { page in
                    ChoiceRow(title: page.exam.name, detail: FolderWording.pageRow(page), isPicked: choice == .page(page.id)) {
                        choice = .page(page.id)
                    }
                    .accessibilityIdentifier("examPage.page.\(page.exam.name)")
                }
                ChoiceRow(title: "No page", detail: "Stays in the \(words.container)’s Folders list", isPicked: choice == .none) {
                    choice = .none
                }
                .accessibilityIdentifier("examPage.none")
                ChoiceRow(title: "New page", detail: newName, isPicked: choice == .new(name: newName)) {
                    choice = .new(name: newName)
                }
                .accessibilityIdentifier("examPage.new")
            }
        }
    }

    private var current: CourseModel.PageChoice {
        folder.examPageID.map { .page($0) } ?? .none
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            problem = await model.put(folder, on: choice)
            isSaving = false
            if problem == nil { dismiss() }
        }
    }
}

/// Move to: the course's folders by exam page, then those on none, then a new folder. The folder
/// the sets are in is shown but cannot be picked.
struct MoveSetsSheet: View {
    let model: CourseModel
    let folder: Folder
    let sets: [PracticeSetSummary]
    /// Called once the sets moved.
    let moved: () -> Void
    @State private var destination: Pick?
    @State private var newName = ""
    @State private var problem: String?
    @State private var isSaving = false
    @FocusState private var naming: Bool
    @Environment(\.dismiss) private var dismiss

    private enum Pick: Hashable {
        case folder(String)
        case new
    }

    var body: some View {
        EditSheet(title: "Move to", confirm: "Move", identifier: "moveSets", isSaving: isSaving, hasChanges: destination != nil, save: save) {
            SheetHint(text: moving)
            if let problem {
                ProblemText(text: problem)
            }
            if let layout = model.layout {
                ForEach(layout.pages.filter { !$0.folders.isEmpty }) { page in
                    group(page.exam.name, page.folders)
                }
                if !layout.looseFolders.isEmpty {
                    group("On no page", layout.looseFolders)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                QBankSectionHeader("Or")
                    .padding(.horizontal, QBankSpacing.space5)
                QBankListGroup {
                    ChoiceRow(title: "New folder", detail: "On no page", isPicked: destination == .new) {
                        destination = .new
                        naming = true
                    }
                    .accessibilityIdentifier("moveSets.new")
                }
                if destination == .new {
                    LabeledField(label: "Folder name") {
                        TextField("Folder name", text: $newName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .focused($naming)
                            .accessibilityIdentifier("moveSets.newName")
                    }
                    .padding(.top, QBankSpacing.space2)
                }
            }
            SheetHint(text: "Answers and progress move with the set.")
        }
    }

    private var moving: String {
        let what = sets.count == 1 ? "“\(sets[0].title)”" : Wording.count(sets.count, "set")
        return "Moving \(what) out of \(folder.name)."
    }

    private func group(_ title: String, _ folders: [Folder]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QBankSectionHeader(title)
                .padding(.horizontal, QBankSpacing.space5)
            QBankListGroup {
                ForEach(folders) { other in
                    let isHere = other.id == folder.id
                    ChoiceRow(
                        title: other.name,
                        detail: isHere ? "Here now" : FolderWording.meta(other),
                        isPicked: destination == .folder(other.id),
                        isEnabled: !isHere
                    ) {
                        destination = .folder(other.id)
                        naming = false
                    }
                    .accessibilityIdentifier("moveSets.folder.\(title).\(other.name)")
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        let target: CourseModel.Destination
        switch destination {
        case .folder(let id):
            target = .folder(id)
        case .new:
            guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                problem = "Folder name is required."
                return
            }
            target = .newFolder(newName)
        case nil:
            problem = "Pick a folder to move to."
            return
        }
        isSaving = true
        Task {
            var target = target
            problem = await model.move(sets, to: &target)
            isSaving = false
            if problem == nil {
                moved()
                dismiss()
            } else if case .folder(let id) = target {
                // The new folder was made before the problem: trying again moves the rest into it.
                destination = .folder(id)
                naming = false
            }
        }
    }
}

/// New folder, from a course's + or an exam page's: one field. On an exam page it goes on the page.
struct NewFolderSheet: View {
    let model: CourseModel
    /// The exam page it goes on, or nil for the course's Folders list.
    var page: CourseExam?
    @State private var name = ""
    @State private var problem: String?
    @State private var isSaving = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EditSheet(title: page.map { "New folder on \($0.name)" } ?? "New folder", confirm: "Done", identifier: "newFolder", isSaving: isSaving, hasChanges: !name.isEmpty, save: save) {
            LabeledField(label: "Folder name") {
                TextField("Folder name", text: $name, prompt: Text("Week 4").foregroundStyle(.qbank(.text4)))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier("newFolder.name")
            }
            if let problem {
                ProblemText(text: problem)
            }
            SheetHint(
                text: page.map { "It goes on \($0.name). Import a question file into it from its page." }
                    ?? "It goes under Folders. Import a question file into it from its page.")
        }
        .onAppear { focused = true }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !isSaving else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "Folder name is required."
            return
        }
        isSaving = true
        Task {
            problem = await model.makeFolder(named: name, on: page?.id)
            isSaving = false
            if problem == nil { dismiss() }
        }
    }
}
