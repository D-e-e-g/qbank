import QBankDesign
import QBankKit
import SwiftUI

/// A folder: which exam page it is on and how far she is, Exam page, Import here and Delete, its
/// sets, and its exam bank. More, at the top right, renames it. Select puts a check circle on each
/// set and a Move bar at the bottom, as Files does. Touching and holding a set offers Delete.
/// Deleting the folder deletes its sets too, after a warning that names them.
struct FolderView: View {
    let app: AppModel
    let model: CourseModel
    let id: String
    /// The set she is practicing, shown full screen over the tabs.
    @State private var practicing: PracticeRoute?
    /// The sets she ticked, while she selects.
    @State private var selection: Set<String>?
    @State private var sheet: Sheet?
    /// The set, exam set, or the folder itself she asked to delete, while its warning is open.
    @State private var deleting: DeleteRequest?
    /// True once the folder is deleted, so the screen leaves instead of saying it is gone.
    @State private var isDeleted = false
    @Environment(TabNavigator.self) private var tabs: TabNavigator?
    @Environment(\.dismiss) private var dismiss

    private enum Sheet: Identifiable {
        case rename
        case page
        case move([PracticeSetSummary])
        case importHere

        var id: String {
            switch self {
            case .rename: "rename"
            case .page: "page"
            case .move: "move"
            case .importHere: "import"
            }
        }
    }

    var body: some View {
        ScrollView {
            if let folder = model.folder(id) {
                content(folder)
                    .screenColumn()
                    .padding(.bottom, QBankSpacing.space7)
            } else if model.course != nil, !isDeleted {
                // Removed elsewhere, such as on the web, while it was open here.
                EmptyCard(message: "This folder is not in the \(model.words.container) anymore.", systemImage: "folder")
                    .screenColumn()
                    .padding(.top, QBankSpacing.space4)
            }
        }
        .qbankScreenBackground()
        .navigationTitle(model.folder(id)?.name ?? "Folder")
        .screenColumnTitle()
        .moreMenu(model.canEdit && model.folder(id) != nil) {
            if let folder = model.folder(id) {
                more(folder)
            }
        }
        .refreshable { await model.load() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let selection, !selection.isEmpty, let folder = model.folder(id) {
                MoveBar(count: selection.count) {
                    sheet = .move(folder.sets.filter { selection.contains($0.id) })
                }
            }
        }
        .practiceCover(app: app, model: model, route: $practicing)
        .onChange(of: app.deletions.revision) {
            // Deleted here, or brought back with Undo while this screen is open.
            Task { await model.load() }
        }
        .deleteSheet(app: app, request: $deleting) { target in
            if case .folder = target {
                isDeleted = true
                dismiss()
            }
        }
        .sheet(item: $sheet, onDismiss: { Task { await model.load() } }, content: { sheet in
            if let folder = model.folder(id) {
                switch sheet {
                case .rename:
                    RenameFolderSheet(model: model, folder: folder)
                case .page:
                    ExamPageSheet(model: model, folder: folder)
                case .move(let sets):
                    MoveSetsSheet(model: model, folder: folder, sets: sets) {
                        selection = nil
                    }
                case .importHere:
                    ImportHereSheet(app: app, courseID: model.id, folderID: folder.id) { set in
                        self.sheet = nil
                        Task { await model.load() }
                        // A replaced set stays in its own folder, which may be another one.
                        if set.folderID != id {
                            tabs?.openFolder(courseID: set.courseID, name: model.course.map(Wording.name), folderID: set.folderID)
                        }
                    }
                }
            }
        })
        .onChange(of: model.folder(id)?.sets.map(\.id)) { _, sets in
            // Sets that left the folder leave the selection, and with none left, selecting ends.
            guard let sets, let current = selection else { return }
            selection = sets.isEmpty ? nil : current.intersection(sets)
        }
    }

    private func content(_ folder: Folder) -> some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space4) {
            Text(FolderWording.folderNote(folder, page: model.page(of: folder)))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("folder.note")
            if model.savedAt != nil {
                OfflineBanner.showingSaved(phoneIsOnline: app.connection.isOnline)
            }
            if let problem = model.problem {
                ProblemText(text: problem)
            }
            // The buttons keep their words on one line and wrap as a row when they do not fit.
            FlowLayout(spacing: QBankSpacing.space2, lineSpacing: QBankSpacing.space2) {
                Button {
                    sheet = .page
                } label: {
                    Label(model.page(of: folder)?.name ?? "Page", systemImage: "square.stack.3d.up")
                }
                .accessibilityLabel("Page: \(model.page(of: folder)?.name ?? "none")")
                .accessibilityIdentifier("folder.page")
                Button {
                    sheet = .importHere
                } label: {
                    Label("Import here", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("folder.import")
                Button {
                    deleting = DeleteRequest(target: .folder(id: folder.id, name: folder.name))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.qbank(.destructive, size: .small))
                .accessibilityLabel("Delete \(folder.name)")
                .accessibilityIdentifier("folder.delete")
            }
            .buttonStyle(.qbank(.secondary, size: .small))
            .disabled(!model.canEdit || selection != nil)
            sets(folder)
                .padding(.top, QBankSpacing.space3)
        }
    }

    /// More: Rename opens the rename sheet. Offline, More is not shown, and while she selects sets
    /// it waits.
    private func more(_ folder: Folder) -> some View {
        MoreMenu(name: folder.name, identifier: "folder.more") {
            Button("Rename", systemImage: "pencil") {
                sheet = .rename
            }
            .accessibilityIdentifier("folder.more.rename")
        }
        .disabled(selection != nil)
    }

    private func sets(_ folder: Folder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(
                title: "Sets",
                action: selection != nil ? "Cancel" : folder.sets.isEmpty ? nil : "Select",
                label: selection != nil ? "Cancel selecting" : "Select sets",
                identifier: "folder.select",
                isEnabled: selection != nil || model.canEdit
            ) {
                selection = selection == nil ? [] : nil
            }
            if folder.sets.isEmpty, folder.examBankCount == 0 {
                EmptyCard(message: "No sets yet. Move sets here from another folder.", systemImage: "folder")
            } else {
                QBankListGroup {
                    ForEach(folder.sets) { set in
                        if let selection {
                            SelectRow(set: set, isSelected: selection.contains(set.id), isStudent: model.isStudent) {
                                toggle(set)
                            }
                        } else {
                            SetRow(set: set, isRestoring: model.isRestoring, isStudent: model.isStudent) {
                                practicing = PracticeRoute(source: .set(id: set.id), courseID: model.id, title: set.title, kind: model.course?.kind ?? .course)
                            } restore: {
                                Task { await model.restore(set) }
                            }
                            .deletable(set.title, isEnabled: model.canEdit) {
                                deleting = DeleteRequest(target: .set(id: set.id, title: set.title))
                            }
                        }
                    }
                    ExamBankLine(folder: folder)
                    if selection == nil {
                        ForEach(folder.examSets) { set in
                            ExamSetRow(set: set)
                                .deletable(set.title, isEnabled: model.canEdit) {
                                    deleting = DeleteRequest(target: .set(id: set.id, title: set.title))
                                }
                        }
                    }
                }
                if selection == nil, model.canEdit {
                    Text("Touch and hold a set to delete it.")
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                        .padding(.horizontal, QBankSpacing.space5)
                }
            }
        }
    }

    private func toggle(_ set: PracticeSetSummary) {
        guard var current = selection else { return }
        if current.contains(set.id) {
            current.remove(set.id)
        } else {
            current.insert(set.id)
        }
        selection = current
    }
}

/// The bar at the bottom while sets are ticked: Move N sets.
private struct MoveBar: View {
    let count: Int
    let move: () -> Void

    var body: some View {
        Button(action: move) {
            Label("Move \(Wording.count(count, "set"))", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
        }
        .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
        .screenColumn()
        .padding(.vertical, QBankSpacing.space3)
        .background(.qbank(.bg))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.qbank(.separator))
                .frame(height: QBankBorder.hairline)
        }
        .accessibilityIdentifier("folder.move")
    }
}

/// A set while she selects: a check circle, its title and how far she got.
private struct SelectRow: View {
    let set: PracticeSetSummary
    let isSelected: Bool
    let isStudent: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: QBankSpacing.space4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(.qbank(isSelected ? .tint : .separatorStrong))
                    .accessibilityHidden(true)
                SetText(set: set, isStudent: isStudent, opens: false)
            }
            .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
            .padding(.vertical, 10)
            .frame(minHeight: QBankSpacing.rowMin)
            .contentShape(.rect)
        }
        .buttonStyle(.qbankRow)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("folder.pick.\(set.title)")
    }
}

/// A practice set in its folder: its title and how far she got. A replaced set offers its previous
/// version back, with Restore beside the row rather than inside it, so each is its own button.
/// Restore asks first.
private struct SetRow: View {
    let set: PracticeSetSummary
    let isRestoring: Bool
    let isStudent: Bool
    let open: () -> Void
    let restore: () -> Void
    @State private var asksToRestore = false

    var body: some View {
        HStack(spacing: 0) {
            if isStudent {
                Button(action: open) {
                    label(showsChevron: !set.canRestore)
                }
                .buttonStyle(.qbankRow)
                .accessibilityIdentifier("course.set.\(set.title)")
            } else {
                label(showsChevron: false)
            }
            if set.canRestore {
                Button("Restore") { asksToRestore = true }
                    .buttonStyle(.qbank(.secondary, size: .small))
                    .disabled(isRestoring)
                    .padding(.trailing, QBankSpacing.rowPaddingHorizontal)
                    .accessibilityLabel("Restore the previous version of \(set.title)")
                    .accessibilityIdentifier("course.restore")
                    .confirmationDialog(
                        "Restore the previous “\(set.title)”?",
                        isPresented: $asksToRestore,
                        titleVisibility: .visible
                    ) {
                        Button("Restore", action: restore)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The set you are looking at stays saved. Restoring brings the previous version back, and you can swap again.")
                    }
            }
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: QBankSpacing.space4) {
            SetText(set: set, isStudent: isStudent, opens: isStudent)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.qbank(.text4))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 10)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A set's title and status line, as the web's folder rows set them: callout over subhead, and
/// under them who imported it when her agent did.
private struct SetText: View {
    let set: PracticeSetSummary
    let isStudent: Bool
    /// Whether tapping the row opens the set, the only row that says Continue.
    let opens: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(set.title)
                .qbankFont(.callout, weight: .semibold)
                .foregroundStyle(.qbank(.text1))
                .multilineTextAlignment(.leading)
            Group {
                if opens, let answered = Wording.continuing(set) {
                    ContinueText(answered: answered)
                } else {
                    QBankDetailText(Wording.status(set, opens: opens))
                }
            }
            .qbankFont(.subheadline)
            .foregroundStyle(.qbank(.text2))
            if set.importedByAgent != nil {
                Text(AgentWording.importedBy(isStudent: isStudent))
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "7 of 12 answered · Continue", with Continue in the tint: on one line when it fits, otherwise one
/// part per line, as `QBankDetailText` lays out a line.
private struct ContinueText: View {
    let answered: String

    private var word: Text {
        Text(Wording.continueWord)
            .fontWeight(.semibold)
            .foregroundStyle(.qbank(.tint))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text("\(answered) · \(word)")
                .lineLimit(1)
            Text("\(answered)\n\(word)")
                .accessibilityLabel("\(answered) · \(Wording.continueWord)")
        }
    }
}

/// An exam set of the folder's exam bank, under its exam line: its title and size, asked only on
/// exams. Not opened for practice.
private struct ExamSetRow: View {
    let set: ExamSetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(set.title)
                .qbankFont(.callout, weight: .semibold)
                .foregroundStyle(.qbank(.text1))
                .multilineTextAlignment(.leading)
            Text(Wording.count(set.questionCount, "question"))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.vertical, 10)
        .frame(minHeight: QBankSpacing.rowMin)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("folder.examSet.\(set.title)")
    }
}

extension View {
    /// Offers Delete when she touches and holds the row, and to VoiceOver as an action.
    func deletable(_ name: String, isEnabled: Bool, delete: @escaping () -> Void) -> some View {
        contextMenu {
            if isEnabled {
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("delete.\(name)")
            }
        }
        .accessibilityActions {
            if isEnabled {
                Button("Delete", action: delete)
            }
        }
    }
}

/// The folder's exam line under its sets: its exam bank, or that its exams use practice questions.
private struct ExamBankLine: View {
    let folder: Folder

    var body: some View {
        Label {
            QBankDetailText(FolderWording.examBank(folder))
        } icon: {
            Image(systemName: "timer")
                .foregroundStyle(.qbank(folder.examBankCount > 0 ? .tint : .text3))
        }
        .qbankFont(.footnote)
        .foregroundStyle(.qbank(.text3))
        .padding(.horizontal, QBankSpacing.rowPaddingHorizontal)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("folder.bank")
    }
}
