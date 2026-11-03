import QBankDesign
import QBankKit
import SwiftUI

/// A page of a course or topic: its folders and sets, Start exam over them, its folders in her
/// order, and the exams she took over them. Edit page, in More beside +, opens the page's name,
/// folders and badge. Study material's Edit puts the folders in order and still offers that
/// editor. The + at the top adds into the page: a question file, a new folder, or folders she has.
/// A topic's page has its primer link when it has one. Its editor ends with Delete: the page goes
/// to Recently deleted, and its folders stay in the course, with their sets, at the end of its
/// Folders list.
struct ExamPageView: View {
    let app: AppModel
    let model: CourseModel
    let id: String
    /// A past or running exam she opened.
    @State private var exam: ExamRoute?
    /// Its folders in her order, while she edits it.
    @State private var order: [String]?
    @State private var isSavingOrder = false
    @State private var editsPage = false
    /// The sheet the + opened, and once a set was filed, the folder to open when it is down.
    @State private var adding: PageSheet?
    @State private var opensFolder: String?
    /// True once the page is deleted, so the screen leaves instead of saying it is gone.
    @State private var isDeleted = false
    /// She asked the editor to delete the page: its warning opens once the editor is down.
    @State private var deletesPage = false
    @State private var problem: String?
    /// The page or a past exam she asked to delete, while its warning is open.
    @State private var deleting: DeleteRequest?
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeNavigator.self) private var navigator: HomeNavigator?
    @Environment(TabNavigator.self) private var tabs: TabNavigator?

    var body: some View {
        ScrollView {
            if let page = model.layout?.page(id) {
                content(page)
                    .screenColumn()
                    .padding(.bottom, QBankSpacing.space7)
            } else if model.course != nil, !isDeleted {
                // Deleted elsewhere, such as on the web, while it was open here.
                EmptyCard(message: model.words.pageGone, systemImage: "square.stack.3d.up")
                    .screenColumn()
                    .padding(.top, QBankSpacing.space4)
            }
        }
        .qbankScreenBackground()
        .navigationTitle(model.layout?.page(id)?.exam.name ?? "Page")
        .screenColumnTitle()
        .plusMenu(model.isStudent && model.layout?.page(id) != nil, more: model.canEdit && model.layout?.page(id) != nil) {
            if let page = model.layout?.page(id) {
                addMenu(page)
            }
        } more: {
            if let page = model.layout?.page(id) {
                more(page)
            }
        }
        .refreshable { await model.load() }
        .onAppear {
            // Back from Exam setup or a folder: an exam she took shows under Past exams.
            Task { await model.load() }
        }
        .examCover(app: app, model: model, route: $exam) { dismiss() }
        .onChange(of: app.deletions.revision) {
            // A folder or exam deleted, or brought back with Undo while this page is open.
            Task { await model.load() }
        }
        .deleteSheet(app: app, request: $deleting) { target in
            if case .examPage = target {
                isDeleted = true
                dismiss()
            }
        }
        .sheet(isPresented: $editsPage, onDismiss: {
            order = nil
            // Delete in the editor asks once the editor is down.
            guard deletesPage, let page = model.layout?.page(id) else { return }
            deletesPage = false
            deleting = DeleteRequest(target: .examPage(id: page.id, name: page.exam.name))
        }, content: {
            if let course = model.course {
                EditExamPageView(app: app, course: course, pageID: id) { outcome in
                    if outcome == .delete {
                        deletesPage = true
                    } else {
                        Task { await model.load() }
                    }
                }
            }
        })
        .sheet(item: $adding, onDismiss: {
            // The folder a set went into opens once the sheet is down.
            guard let folder = opensFolder else { return }
            opensFolder = nil
            navigator?.open(CoursePage.folder(folder))
        }, content: { sheet in
            if let page = model.layout?.page(id) {
                switch sheet {
                case .importFile:
                    ImportHereSheet(app: app, courseID: model.id, folderID: page.folders.first?.id, examPageID: page.id) { set in
                        adding = nil
                        Task { await model.load() }
                        if set.courseID == model.id {
                            opensFolder = set.folderID
                        } else {
                            // She picked another course in the sheet.
                            tabs?.openFolder(courseID: set.courseID, name: nil, folderID: set.folderID)
                        }
                    }
                case .newFolder:
                    NewFolderSheet(model: model, page: page.exam)
                }
            }
        })
    }

    /// The + at the top: "Add to Exam 1", then Import a question file here, New folder on this
    /// page, and while the course has folders on no page, Add existing folders, which opens the
    /// page's editor.
    private func addMenu(_ page: ExamPage) -> some View {
        Menu {
            Section("Add to \(page.exam.name)") {
                Button {
                    adding = .importFile
                } label: {
                    Text("Import a question file here")
                    Text("A JSON file from your agent")
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityIdentifier("page.add.import")
                Button("New folder on this page", systemImage: "folder.badge.plus") {
                    adding = .newFolder
                }
                .accessibilityIdentifier("page.add.folder")
                if model.layout?.looseFolders.isEmpty == false {
                    Button("Add existing folders", systemImage: "folder") {
                        editsPage = true
                    }
                    .accessibilityIdentifier("page.add.existing")
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!model.canEdit || order != nil)
        .accessibilityLabel("Add to \(page.exam.name)")
        .accessibilityIdentifier("page.add")
    }

    private func content(_ page: ExamPage) -> some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space4) {
            Text(FolderWording.pageNote(page))
                .qbankFont(.subheadline)
                .foregroundStyle(.qbank(.text2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("page.note")
            if let link = page.exam.linkURL {
                PrimerRow(address: link)
            }
            if let problem = problem ?? model.problem {
                ProblemText(text: problem)
            }
            if model.isStudent, page.examQuestionCount > 0, let setup = model.examSetup(for: page) {
                VStack(alignment: .leading, spacing: QBankSpacing.space2) {
                    NavigationLink(value: StudyRoute.exam(setup)) {
                        Label("Start exam", systemImage: "timer")
                    }
                    .buttonStyle(.qbank(.primary, size: .large, fullWidth: true))
                    .accessibilityIdentifier("page.startExam")
                    if let draw = model.plan(for: page).flatMap(FolderWording.examDraw) {
                        Text(draw)
                            .qbankFont(.footnote)
                            .foregroundStyle(.qbank(.text3))
                            .padding(.horizontal, QBankSpacing.space1)
                            .accessibilityIdentifier("page.draw")
                    }
                    if let twins = FolderWording.examTwins(page) {
                        Label {
                            QBankDetailText(twins)
                        } icon: {
                            Image(systemName: "timer")
                                .foregroundStyle(.qbank(.tint))
                                .accessibilityHidden(true)
                        }
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                        .padding(.horizontal, QBankSpacing.space1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("page.twins")
                    }
                }
            }
            folders(page)
                .padding(.top, QBankSpacing.space3)
            sittings(page)
                .padding(.top, QBankSpacing.space3)
        }
    }

    private func folders(_ page: ExamPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(
                title: "Study material",
                action: order == nil ? "Edit" : "Done",
                label: order == nil ? "Edit study material" : "Done, save folder order",
                identifier: "page.edit",
                isEnabled: !isSavingOrder && (order != nil || model.canEdit)
            ) {
                edit(page)
            }
            if order != nil {
                Button {
                    openEditor(page)
                } label: {
                    Label("Name and folders of \(page.exam.name)", systemImage: "pencil")
                }
                .buttonStyle(.qbank(.secondary, size: .medium, fullWidth: true))
                .disabled(isSavingOrder)
                .padding(.bottom, QBankSpacing.space2)
                .accessibilityIdentifier("page.editPage")
            }
            if page.folders.isEmpty {
                EmptyCard(message: model.isStudent ? "No folders on this page yet. Add the folders this page covers." : "No folders on this page yet.", systemImage: "folder")
            } else {
                FolderList(folders: page.folders, order: $order)
                if order != nil, page.folders.count > 1 {
                    Text("Drag a folder by its grip, or use the arrows, to put them in your order.")
                        .qbankFont(.footnote)
                        .foregroundStyle(.qbank(.text3))
                        .padding(.horizontal, QBankSpacing.space5)
                }
            }
        }
    }

    @ViewBuilder
    private func sittings(_ page: ExamPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(title: model.isStudent ? "Past exams" : "Her past exams")
            if page.sittings.isEmpty {
                EmptyCard(
                    message: model.isStudent
                        ? "Exams you finish over \(page.exam.name) show up here with their scores."
                        : "Her finished exams over \(page.exam.name) show up here with their scores.",
                    systemImage: "timer"
                )
            } else {
                QBankListGroup(footer: model.isStudent && model.canEdit ? "Touch and hold an exam to delete it." : nil) {
                    ForEach(page.sittings) { sitting in
                        Button {
                            exam = ExamRoute(id: sitting.id)
                        } label: {
                            PastExamRow(exam: sitting)
                        }
                        .buttonStyle(.qbankRow)
                        .deletable("exam", isEnabled: model.isStudent && model.canEdit && sitting.finishedAt != nil) {
                            deleting = DeleteRequest(target: .exam(id: sitting.id))
                        }
                        .accessibilityIdentifier("page.sitting.\(sitting.id)")
                    }
                }
            }
        }
    }

    /// More, beside +: Edit page opens the page's name, badge and folders. An order she has not
    /// saved yet is saved first, the same as Name and folders. Offline, More is not shown.
    private func more(_ page: ExamPage) -> some View {
        MoreMenu(name: page.exam.name, identifier: "page.more") {
            Button("Edit page", systemImage: "pencil") {
                openEditor(page)
            }
            .disabled(isSavingOrder)
            .accessibilityIdentifier("page.more.editPage")
        }
    }

    /// The page's editor starts from its saved folders, so an order she changed is saved first. If
    /// that is refused, she reads why and the editor stays closed.
    private func openEditor(_ page: ExamPage) {
        guard let edited = order, edited != page.folders.map(\.id) else {
            editsPage = true
            return
        }
        isSavingOrder = true
        Task {
            problem = await model.saveOrder(page: page.id, folderIDs: edited)
            isSavingOrder = false
            if problem == nil {
                editsPage = true
            } else {
                order = nil
            }
        }
    }

    /// Edit puts the folders in order mode and offers the page's editor; Done saves her order when
    /// it changed.
    private func edit(_ page: ExamPage) {
        guard let edited = order else {
            problem = nil
            order = page.folders.map(\.id)
            return
        }
        guard edited != page.folders.map(\.id) else {
            order = nil
            return
        }
        isSavingOrder = true
        Task {
            problem = await model.saveOrder(page: page.id, folderIDs: edited)
            isSavingOrder = false
            order = nil
        }
    }
}

/// A sheet an exam page's + opens.
private enum PageSheet: String, Identifiable {
    case importFile
    case newFolder

    var id: String { rawValue }
}

/// A topic page's primer: the page where she wrote it up, opened in the browser. Nothing of it is
/// shown here but where it lives.
private struct PrimerRow: View {
    let address: String

    var body: some View {
        QBankListGroup {
            if let url = URL(string: address), url.host() != nil {
                Link(destination: url) {
                    row(detail: url.host() ?? address) {
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.qbank(.text4))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.qbankRow)
                .accessibilityHint("Opens in Safari")
                .accessibilityIdentifier("page.primer")
            } else {
                row(detail: address) { EmptyView() }
                    .accessibilityIdentifier("page.primer")
            }
        }
    }

    private func row(detail: String, @ViewBuilder accessory: () -> some View) -> some View {
        QBankListRow("Open the primer", detail: detail, systemImage: "link", accessory: accessory)
    }
}
