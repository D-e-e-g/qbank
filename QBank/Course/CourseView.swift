import QBankDesign
import QBankKit
import SwiftUI

/// A course: the score line, the Exam, Review and Terms tiles, then two lists, as the iPhone
/// Files app lists things: her pages, each with its badge, and the folders on no page. Each page
/// and each folder opens as its own screen, sharing this screen's model. A study topic is the
/// same screen, called by its name; `Wording.words(_:)` picks what differs. Rename, in More
/// beside +, changes the name only. Holding the card on Home still renames it too.
///
/// The + at the top adds into the course: a question file, questions made from her material, a
/// folder, or an exam page. More, beside it, renames the course or topic.
struct CourseView: View {
    let app: AppModel
    let route: CourseRoute
    @State private var model: CourseModel
    /// The sheet the + opened, and once it made a page or filed a set, the screen to open when it
    /// is down.
    @State private var sheet: CourseSheet?
    @State private var opensNext: CoursePage?
    /// The rename sheet, from More beside +.
    @State private var renamesCourse = false
    /// The folders on no exam page in her order, while she edits it.
    @State private var order: [String]?
    @State private var isSavingOrder = false
    /// Why her order was not saved, in the server's words.
    @State private var orderProblem: String?
    @Environment(HomeNavigator.self) private var navigator: HomeNavigator?
    @Environment(TabNavigator.self) private var tabs: TabNavigator?

    init(app: AppModel, route: CourseRoute) {
        self.app = app
        self.route = route
        _model = State(initialValue: CourseModel(app: app, id: route.id))
    }

    var body: some View {
        ScrollView {
            content
                .screenColumn()
                .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle(model.course.map(Wording.name) ?? route.name ?? "Course")
        .screenColumnTitle()
        .plusMenu(model.isStudent && model.course != nil, more: showsRename) {
            if let course = model.course {
                addMenu(course)
            }
        } more: {
            renameMenu
        }
        .refreshable { await model.load() }
        .reloadsWithConnection(app) {
            await model.load()
            await model.loadMaker()
        }
        .task {
            async let place: Void = model.rememberPlace()
            async let maker: Void = model.loadMaker()
            await model.load()
            await place
            await maker
        }
        .onAppear {
            // Back from Review, Terms or an exam: its counts may have changed.
            guard model.course != nil else { return }
            Task { await model.load() }
        }
        .onChange(of: app.deletions.revision) {
            // Deleted or brought back on one of its screens, or with Undo: its lists change.
            Task { await model.load() }
        }
        .onChange(of: model.course) { old, _ in
            // On iPad the courses stay beside this one, and their card shows these counts too.
            if old != nil {
                navigator?.courseChanged()
            }
        }
        .navigationDestination(for: CoursePage.self) { page in
            switch page {
            case .examPage(let id): ExamPageView(app: app, model: model, id: id)
            case .folder(let id): FolderView(app: app, model: model, id: id)
            case .recentlyDeleted: RecentlyDeletedView(app: app, courseID: model.id)
            }
        }
        .sheet(isPresented: $renamesCourse, onDismiss: {
            Task { await model.load() }
        }) {
            if let course = model.course {
                RenameCourseView(app: app, detail: course)
            }
        }
        .sheet(item: $sheet, onDismiss: {
            // A new page, or the folder a set went into, opens once the sheet is down.
            guard let next = opensNext else { return }
            opensNext = nil
            navigator?.open(next)
        }, content: { sheet in
            if let course = model.course {
                switch sheet {
                case .importFile:
                    ImportHereSheet(app: app, courseID: course.id) { set in
                        self.sheet = nil
                        Task { await model.load() }
                        if set.courseID == course.id {
                            opensNext = .folder(set.folderID)
                        } else {
                            // She picked another course in the sheet.
                            tabs?.openFolder(courseID: set.courseID, name: nil, folderID: set.folderID)
                        }
                    }
                case .newFolder:
                    NewFolderSheet(model: model)
                case .newPage:
                    EditExamPageView(app: app, course: course, pageID: nil) { outcome in
                        Task { await model.load() }
                        if case .saved(let id) = outcome { opensNext = .examPage(id) }
                    }
                }
            }
        })
    }

    /// The + at the top: "Add to NURS 310", then Import a question file, Make questions when the
    /// server allows it, New folder, and New page.
    private func addMenu(_ course: CourseDetail) -> some View {
        Menu {
            Section("Add to \(Wording.name(course))") {
                Button {
                    sheet = .importFile
                } label: {
                    Text("Import a question file")
                    Text("A JSON file from your agent")
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityIdentifier("course.add.import")
                if model.canMake {
                    Button {
                        tabs?.makeQuestions(courseID: course.id, status: model.maker)
                    } label: {
                        Text("Make questions")
                        Text("From your notes or photos")
                        Image(systemName: "sparkles")
                    }
                    .accessibilityIdentifier("course.add.make")
                }
                Button("New folder", systemImage: "folder.badge.plus") {
                    sheet = .newFolder
                }
                .accessibilityIdentifier("course.add.folder")
                Button("New page", systemImage: "square.stack.3d.up") {
                    sheet = .newPage
                }
                .accessibilityIdentifier("course.add.page")
            }
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!model.canEdit || order != nil)
        .accessibilityLabel("Add to \(Wording.name(course))")
        .accessibilityIdentifier("course.add")
    }

    /// Rename is offered to the student, for a topic and for a course that is in a semester.
    /// A read-only admin does not get More. Offline, nothing here can be renamed.
    private var showsRename: Bool {
        guard model.isStudent, model.canEdit, let course = model.course else { return false }
        return course.kind == .topic || course.semester != nil
    }

    /// More, beside +: Rename opens the same sheet Home opens from holding the card. Its button
    /// is named "More for NURS 310", or "More for" a topic's title.
    private var renameMenu: some View {
        MoreMenu(name: model.course.map(Wording.name) ?? "", identifier: "course.more") {
            Button("Rename", systemImage: "pencil") {
                renamesCourse = true
            }
            .accessibilityIdentifier("course.rename")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let course = model.course, let ref = model.ref, let layout = model.layout {
            VStack(alignment: .leading, spacing: QBankSpacing.space4) {
                summary(course)
                if model.savedAt != nil {
                    OfflineBanner.showingSaved(phoneIsOnline: app.connection.isOnline)
                        .accessibilityIdentifier("course.offline")
                }
                if let problem = orderProblem ?? model.problem {
                    ProblemText(text: problem)
                }
                tiles(course, ref: ref)
                if course.folders.isEmpty, layout.pages.isEmpty {
                    EmptyCard(message: "This \(model.words.container) has no question sets yet.")
                        .padding(.top, QBankSpacing.space3)
                } else {
                    pages(layout)
                        .padding(.top, QBankSpacing.space3)
                    if !layout.looseFolders.isEmpty {
                        folders(layout)
                            .padding(.top, QBankSpacing.space3)
                    }
                }
                recentlyDeleted
                    .padding(.top, QBankSpacing.space3)
            }
        } else if let problem = model.problem {
            LoadFailed(problem: problem) {
                Task { await model.load() }
            }
        } else {
            Loading(title: "Loading the \(Wording.words(route.kind).container)")
        }
    }

    private func summary(_ course: CourseDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Wording.summary(course))
            if let score = Wording.score(course) {
                Text(score)
            }
        }
        .qbankFont(.subheadline)
        .foregroundStyle(.qbank(.text2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("course.summary")
    }

    private func tiles(_ course: CourseDetail, ref: CourseRef) -> some View {
        HStack(spacing: QBankSpacing.space3) {
            NavigationLink(value: StudyRoute.exam(ExamSetupRoute(course: ref))) {
                Tile(systemImage: "timer", value: "Exam", label: Wording.examTime(course))
            }
            .accessibilityIdentifier("course.tile.exam")
            NavigationLink(value: StudyRoute.review(ref)) {
                Tile(systemImage: "tray", value: "\(course.reviewCount)", label: "to review")
            }
            .accessibilityIdentifier("course.tile.review")
            NavigationLink(value: StudyRoute.terms(ref)) {
                Tile(systemImage: "book", value: "\(course.termCount)", label: course.termCount == 1 ? "term" : "terms")
            }
            .accessibilityIdentifier("course.tile.terms")
        }
        .buttonStyle(QBankCardButtonStyle(padding: QBankSpacing.space4))
    }

    private func pages(_ layout: CourseLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(title: "Pages")
            if layout.pages.isEmpty {
                EmptyCard(message: model.isStudent
                    ? "No pages yet. Tap + to make \(model.nextPageName)."
                    : "No pages yet.", systemImage: "square.stack.3d.up")
                    .accessibilityIdentifier("course.noPages")
            } else {
                QBankListGroup {
                    ForEach(layout.pages) { page in
                        NavigationLink(value: CoursePage.examPage(page.id)) {
                            ExamPageRow(page: page)
                        }
                        .buttonStyle(.qbankRow)
                        .accessibilityIdentifier("course.page.\(page.exam.name)")
                    }
                }
            }
        }
    }

    private func folders(_ layout: CourseLayout) -> some View {
        // As on the web, ordering is offered only when there are two folders to put in order, and
        // while the phone can save it. Done stays while she is already ordering.
        let hasOrder = layout.looseFolders.count > 1
        let offersEdit = order != nil || (hasOrder && model.canEdit)
        return VStack(alignment: .leading, spacing: 6) {
            SectionHead(
                title: "Folders",
                action: offersEdit ? (order == nil ? "Edit" : "Done") : nil,
                label: order == nil ? "Edit folder order" : "Done, save folder order",
                identifier: "course.editFolders",
                isEnabled: !isSavingOrder
            ) {
                editOrder(layout.looseFolders)
            }
            FolderList(folders: layout.looseFolders, order: $order)
            Text(order == nil ? "Folders on no page. Open one to see its sets." : "Drag a folder by its grip, or use the arrows, to put them in your order.")
                .qbankFont(.footnote)
                .foregroundStyle(.qbank(.text3))
                .padding(.horizontal, QBankSpacing.space5)
            if hasOrder, !offersEdit {
                Text("Putting folders in order needs a connection.")
                    .qbankFont(.footnote)
                    .foregroundStyle(.qbank(.text3))
                    .padding(.horizontal, QBankSpacing.space5)
                    .accessibilityIdentifier("course.orderNeedsConnection")
            }
        }
    }

    /// What she deleted in the course, for 30 days.
    private var recentlyDeleted: some View {
        QBankListGroup {
            NavigationLink(value: CoursePage.recentlyDeleted) {
                QBankListRow("Recently deleted", detail: "Bring back pages, folders, sets and exams for 30 days", systemImage: "trash", showsChevron: true)
            }
            .buttonStyle(.qbankRow)
            .disabled(order != nil)
            .accessibilityIdentifier("course.recentlyDeleted")
        }
    }

    /// Edit puts the list in order mode; Done saves her order when it changed.
    private func editOrder(_ folders: [Folder]) {
        guard let edited = order else {
            orderProblem = nil
            order = folders.map(\.id)
            return
        }
        guard edited != folders.map(\.id) else {
            order = nil
            return
        }
        isSavingOrder = true
        Task {
            orderProblem = await model.saveOrder(page: nil, folderIDs: edited)
            isSavingOrder = false
            order = nil
        }
    }

}

/// A sheet the course's + opens.
private enum CourseSheet: String, Identifiable {
    case importFile
    case newFolder
    case newPage

    var id: String { rawValue }
}

extension View {
    /// Practice over the tabs, from a set of the course. Her answers change the set's line and the
    /// course's score, so the course is read again when it closes.
    func practiceCover(app: AppModel, model: CourseModel, route: Binding<PracticeRoute?>) -> some View {
        fullScreenCover(item: route, onDismiss: {
            Task { await model.load() }
        }, content: { route in
            PracticeView(app: app, route: route)
        })
    }

    /// A past or running exam over the tabs. Open Review goes to the course's Review list; Back to
    /// course does what `backToCourse` says.
    func examCover(app: AppModel, model: CourseModel, route: Binding<ExamRoute?>, backToCourse: @escaping () -> Void = {}) -> some View {
        modifier(ExamCover(app: app, model: model, route: route, backToCourse: backToCourse))
    }
}

private struct ExamCover: ViewModifier {
    let app: AppModel
    let model: CourseModel
    @Binding var route: ExamRoute?
    let backToCourse: () -> Void
    @State private var exit: ExamExit?
    @Environment(HomeNavigator.self) private var navigator: HomeNavigator?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $route, onDismiss: closed) { route in
            ExamView(app: app, examID: route.id, kind: model.course?.kind ?? .course) { how in
                exit = how
                self.route = nil
            }
        }
    }

    private func closed() {
        Task { await model.load() }
        switch exit {
        case .openReview:
            if let ref = model.ref { navigator?.open(StudyRoute.review(ref)) }
        case .backToCourse:
            backToCourse()
        case .done, nil:
            break
        }
        exit = nil
    }
}

/// One of the three study tiles under the course title.
private struct Tile: View {
    let systemImage: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.qbank(.tint))
                .frame(height: 26)
                .padding(.bottom, QBankSpacing.space3)
                .accessibilityHidden(true)
            Text(value)
                .qbankFont(.title2)
                .monospacedDigit()
                .foregroundStyle(.qbank(.text1))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .qbankFont(.footnote)
                .foregroundStyle(.qbank(.text2))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
