import QBankDesign
import QBankKit
import SwiftUI

/// The Home tab: her courses by semester, then her study topics, then what she archived, closed
/// until she opens it, and last, once she deleted a course or topic, Recently deleted. Opens the
/// course or topic she used last on arrival. Without a connection it shows the courses saved on the
/// phone, and how many answers wait to be sent.
///
/// The + at the top adds a course to a semester, a study topic, or the next semester. Touching and
/// holding a course or topic opens, renames, moves, archives or deletes it.
///
/// On iPhone, a course opens over the list. On iPad, the list stays in a sidebar and the course
/// opens beside it, with its own screens; an iPad sharing its screen narrows it to one column.
struct HomeView: View {
    let app: AppModel
    @State private var model: HomeModel
    @Bindable private var navigator: HomeNavigator
    /// The sheet the + or a held card opened, and once she made a course or topic in it, the one
    /// to open when it is down.
    @State private var sheet: HomeSheet?
    @State private var made: CourseRoute?
    @State private var showsArchived = false
    /// The course or topic whose Delete she chose, while its question is open.
    @State private var deleting: DeleteRequest?

    init(app: AppModel, navigator: HomeNavigator) {
        self.app = app
        self.navigator = navigator
        _model = State(initialValue: HomeModel(app: app))
    }

    var body: some View {
        Group {
            if navigator.isSplit {
                split
            } else {
                stack
            }
        }
        .environment(navigator)
        .sheet(item: $sheet, onDismiss: {
            guard let route = made else {
                Task { await model.load() }
                return
            }
            made = nil
            navigator.open(route)
        }, content: { sheet in
            switch sheet {
            case .newCourse(let semester):
                NewCourseView(app: app, catalog: model.catalog, semester: semester) { course in
                    made = await model.made(course)
                }
            case .newTopic:
                NewTopicView(app: app) { topic in
                    made = await model.made(topic)
                }
            case .rename(let course):
                RenameCourseView(app: app, catalog: model.catalog, course: course)
            }
        })
        .deleteSheet(app: app, request: $deleting) { target in
            if case .course(let id, _) = target {
                navigator.closeDeleted(courseID: id)
            }
        }
        .onChange(of: app.deletions.revision) {
            // A course or topic deleted, or brought back with Undo or from Recently deleted.
            Task { await model.load() }
        }
        .task {
            await model.load()
            model.saveForOffline()
            if let landing = await model.landingCourse(), navigator.path.isEmpty, navigator.course == nil {
                navigator.open(landing)
            }
        }
    }

    /// iPhone: the courses, and a course pushed over them.
    private var stack: some View {
        NavigationStack(path: $navigator.path) {
            courses
                .onAppear {
                    // Back from a course: its counts may have changed.
                    guard model.catalog != nil else { return }
                    Task { await model.load() }
                }
                .navigationDestination(for: CourseRoute.self) { route in
                    CourseView(app: app, route: route)
                }
                .studyDestinations(app: app)
        }
        .undoBar(app)
        .frozenNote(app.frozen)
    }

    /// iPad: the courses in a sidebar, and the course she chose beside them.
    private var split: some View {
        NavigationSplitView(preferredCompactColumn: $navigator.compactColumn) {
            courses
                .navigationSplitViewColumnWidth(QBankLayout.sidebarWidth)
        } detail: {
            NavigationStack(path: $navigator.path) {
                Group {
                    if let course = navigator.course {
                        CourseView(app: app, route: course)
                            // Another course gets a screen of its own.
                            .id(course.id)
                    } else {
                        NoCourseChosen(hasCourses: model.catalog.map { !$0.everyCourse.isEmpty })
                    }
                }
                .studyDestinations(app: app)
            }
            .undoBar(app)
            .frozenNote(app.frozen)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: navigator.courseRevision) {
            // The open course's counts changed, after practice or an exam: the list follows.
            Task { await model.load() }
        }
    }

    private var courses: some View {
        ScrollView {
            content
                .padding(.horizontal, QBankSpacing.gutterPhone)
                .padding(.bottom, QBankSpacing.space7)
        }
        .qbankScreenBackground()
        .navigationTitle("Home")
        .plusMenu(true) {
            addMenu
        }
        .toolbar {
            if let waiting = app.offline?.waiting.count, waiting > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    savedForOffline {
                        WaitingLabel(count: waiting)
                    }
                    .accessibilityIdentifier("home.waiting")
                }
            } else if let refused = app.offline?.notSaved.count, refused > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    savedForOffline {
                        Text("\(Image(systemName: "exclamationmark.circle")) \(refused) not saved")
                            .foregroundStyle(.qbank(.wrong))
                            .accessibilityLabel("\(Wording.count(refused, "answer")) not saved")
                    }
                    .accessibilityIdentifier("home.notSaved")
                }
            }
        }
        .refreshable {
            await model.load()
            model.saveForOffline(force: true)
        }
        .reloadsWithConnection(app) {
            await model.load()
            model.saveForOffline()
        }
    }

    /// The + at the top: a course in each semester she studies, a study topic, and while one of
    /// the three is missing, the next semester.
    private var addMenu: some View {
        Menu {
            Section("Add") {
                ForEach(model.studiedSemesters) { semester in
                    Button("New course in \(semester.name)", systemImage: "book.closed") {
                        app.frozen.perform { sheet = .newCourse(semester) }
                    }
                    .accessibilityIdentifier("home.add.course.\(semester.number)")
                }
                Button("New study topic", systemImage: "text.book.closed") {
                    app.frozen.perform { sheet = .newTopic }
                }
                .accessibilityIdentifier("home.add.topic")
            }
            if let number = model.nextSemesterNumber {
                Button("Add Semester \(number)", systemImage: "calendar.badge.plus") {
                    Task { await model.addSemester() }
                }
                .accessibilityIdentifier("home.add.semester")
            }
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!model.offersEditing || model.catalog == nil)
        .accessibilityLabel("Add")
        .accessibilityIdentifier("home.add")
    }

    /// Opens Saved for offline: over Home on iPhone, beside it on iPad.
    private func savedForOffline(@ViewBuilder label: () -> some View) -> some View {
        opening(SavedForOfflineRoute(), label: label)
    }

    /// Opens a screen of Home's: over it on iPhone, beside it on iPad.
    @ViewBuilder
    private func opening(_ route: some Hashable, @ViewBuilder label: () -> some View) -> some View {
        if navigator.isSplit {
            Button {
                navigator.open(route)
            } label: {
                label()
            }
        } else {
            NavigationLink(value: route, label: label)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let catalog = model.catalog {
            LazyVStack(alignment: .leading, spacing: QBankSpacing.space4) {
                if model.savedAt != nil {
                    OfflineBanner.showingSaved(phoneIsOnline: app.connection.isOnline)
                        .padding(.top, QBankSpacing.space3)
                        .accessibilityIdentifier("home.offline")
                }
                if let problem = model.editProblem ?? model.problem ?? app.offline?.problem {
                    ProblemText(text: problem)
                        .padding(.top, QBankSpacing.space3)
                }
                if catalog.semesters.isEmpty {
                    EmptyCard(message: "No semesters yet. Tap + to add one, or import a question file.")
                        .padding(.top, QBankSpacing.space3)
                }
                ForEach(model.studiedSemesters) { semester in
                    let courses = model.courses(in: semester)
                    QBankSectionHeader(semester.name)
                        .padding(.horizontal, QBankSpacing.space1)
                        .padding(.top, QBankSpacing.space5)
                        .padding(.bottom, -QBankSpacing.space2)
                    if courses.isEmpty {
                        EmptyCard(message: "No courses yet. Tap + to add one, or import its first question file.")
                    }
                    ForEach(courses) { course in
                        courseLink(course)
                    }
                }
                topics
                if !model.archived.isEmpty {
                    archived
                }
                if let deleted = model.recentlyDeleted, !deleted.courses.isEmpty {
                    recentlyDeleted(deleted)
                        .padding(.top, QBankSpacing.space5)
                }
            }
        } else if let problem = model.problem {
            LoadFailed(problem: problem) {
                Task { await model.load() }
            }
        } else {
            Loading(title: "Loading your courses")
        }
    }

    /// Her study topics. The + at the top makes one.
    @ViewBuilder
    private var topics: some View {
        let topics = model.topics
        QBankSectionHeader("Study topics")
            .padding(.horizontal, QBankSpacing.space1)
            .padding(.top, QBankSpacing.space5)
            .padding(.bottom, -QBankSpacing.space2)
        if topics.isEmpty {
            EmptyCard(message: "A topic is a place for questions that are not a course: a certification, a language, your own notes.", systemImage: "book.closed")
                .accessibilityIdentifier("home.noTopics")
        }
        ForEach(topics) { topic in
            courseLink(topic)
        }
    }

    /// What she archived, last and closed until she opens it, as the web's Archived group.
    @ViewBuilder
    private var archived: some View {
        Button {
            withAnimation(QBankMotion.reveal) { showsArchived.toggle() }
        } label: {
            HStack(spacing: 6) {
                QBankSectionHeader("Archived")
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.qbank(.text3))
                    .rotationEffect(.degrees(showsArchived ? 90 : 0))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: QBankSpacing.rowMin)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, QBankSpacing.space1)
        .padding(.top, QBankSpacing.space3)
        .padding(.bottom, -QBankSpacing.space3)
        .accessibilityValue(showsArchived ? "Open" : "Closed")
        .accessibilityHint(showsArchived ? "Closes the archived courses and topics" : "Opens the archived courses and topics")
        .accessibilityIdentifier("home.archived")
        if showsArchived {
            ForEach(model.archived) { group in
                Text(group.title)
                    .qbankFont(.subheadline, weight: .semibold)
                    .foregroundStyle(.qbank(.text2))
                    .padding(.horizontal, QBankSpacing.space1)
                    .padding(.top, QBankSpacing.space3)
                    .padding(.bottom, -QBankSpacing.space2)
                    .accessibilityAddTraits(.isHeader)
                if group.courses.isEmpty {
                    EmptyCard(message: "No courses.")
                }
                ForEach(group.courses) { course in
                    courseLink(course)
                }
            }
        }
    }

    /// Home's last row, once she deleted a course or topic: Recently deleted, which brings each back
    /// for 30 days.
    private func recentlyDeleted(_ deleted: RecentlyDeletedCourses) -> some View {
        QBankListGroup {
            opening(DeletedCoursesRoute()) {
                QBankListRow(
                    "Recently deleted",
                    detail: DeletedCoursesWording.entry(count: deleted.courses.count, undoDays: deleted.undoDays),
                    systemImage: "trash",
                    showsChevron: true
                )
            }
            .buttonStyle(.qbankRow)
            .accessibilityIdentifier("home.recentlyDeleted")
        }
    }

    /// A course or topic card: pushes it on iPhone, and on iPad shows it beside the list, marked
    /// as the one open. Touching and holding it opens its menu.
    private func courseLink(_ course: CourseSummary) -> some View {
        cardLink(course)
            .contextMenu {
                heldMenu(course)
            }
    }

    /// What holding a card offers: Open, then while QBank can be reached, Rename, Move to each other
    /// semester she studies (a course only), Archive, or Unarchive for one she archived, and last, in
    /// red, Delete, which asks once and keeps it 30 days in Recently deleted.
    @ViewBuilder
    private func heldMenu(_ course: CourseSummary) -> some View {
        Button("Open", systemImage: "arrow.right.circle") {
            navigator.open(CourseRoute(id: course.id, name: Wording.name(course), kind: course.kind))
        }
        .accessibilityIdentifier("home.hold.open")
        if model.offersEditing {
            Button("Rename", systemImage: "pencil") {
                app.frozen.perform { sheet = .rename(course) }
            }
            .accessibilityIdentifier("home.hold.rename")
            if course.kind == .topic {
                if model.canMove(course, by: -1) {
                    Button("Move up", systemImage: "arrow.up") {
                        Task { await model.move(course, by: -1) }
                    }
                    .accessibilityIdentifier("home.hold.up")
                }
                if model.canMove(course, by: 1) {
                    Button("Move down", systemImage: "arrow.down") {
                        Task { await model.move(course, by: 1) }
                    }
                    .accessibilityIdentifier("home.hold.down")
                }
            } else {
                ForEach(model.otherSemesters(than: course)) { semester in
                    Button("Move to \(semester.name)", systemImage: "arrow.right.square") {
                        Task { await model.move(course, to: semester) }
                    }
                    .accessibilityIdentifier("home.hold.move.\(semester.number)")
                }
            }
            if model.canArchive(course) {
                Button {
                    Task { await model.setArchived(course, true) }
                } label: {
                    Text("Archive")
                    Text("Goes to Archived at the bottom of Home")
                    Image(systemName: "archivebox")
                }
                .accessibilityIdentifier("home.hold.archive")
            } else if course.archivedAt != nil {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    Task { await model.setArchived(course, false) }
                }
                .accessibilityIdentifier("home.hold.unarchive")
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                app.frozen.perform { deleting = DeleteRequest(target: .course(id: course.id, name: Wording.name(course))) }
            }
            .accessibilityIdentifier("home.hold.delete")
        }
    }

    @ViewBuilder
    private func cardLink(_ course: CourseSummary) -> some View {
        let route = CourseRoute(id: course.id, name: Wording.name(course), kind: course.kind)
        let card = CourseCard(course: course, savedAt: model.savedAt(course), isNarrow: navigator.isSplit)
        if navigator.isSplit {
            let isOpen = navigator.course?.id == course.id
            Button {
                navigator.select(route)
            } label: {
                card
            }
            .buttonStyle(QBankCardButtonStyle(padding: QBankSpacing.space4))
            .overlay {
                if isOpen {
                    RoundedRectangle(cornerRadius: QBankRadius.md, style: .continuous)
                        .strokeBorder(.qbank(.tint), lineWidth: QBankBorder.emphasis)
                }
            }
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .accessibilityIdentifier(Self.identifier(course))
        } else {
            NavigationLink(value: route) {
                card
            }
            .buttonStyle(QBankCardButtonStyle(padding: QBankSpacing.space4))
            .accessibilityIdentifier(Self.identifier(course))
        }
    }

    /// "home.course.NURS 310", or for a topic, "home.topic." and its name.
    private static func identifier(_ course: CourseSummary) -> String {
        course.kind == .topic ? "home.topic.\(course.title)" : "home.course.\(course.code)"
    }
}

extension View {
    /// The screens a course leads to, on Home's navigation stack: Review, Terms, the Exam, its exam
    /// twins, and Saved for offline and Recently deleted.
    func studyDestinations(app: AppModel) -> some View {
        navigationDestination(for: StudyRoute.self) { route in
            switch route {
            case .review(let course): ReviewView(app: app, course: course)
            case .terms(let course): TermsView(app: app, course: course)
            case .exam(let setup): ExamSetupView(app: app, route: setup)
            case .twinJob(let job): TwinJobView(app: app, route: job)
            }
        }
        .navigationDestination(for: SavedForOfflineRoute.self) { _ in
            SavedForOfflineView(app: app)
        }
        .navigationDestination(for: DeletedCoursesRoute.self) { _ in
            DeletedCoursesView(app: app)
        }
    }
}

/// A sheet over Home: a new course in a semester, a new study topic, or renaming a held card.
private enum HomeSheet: Identifiable {
    case newCourse(Semester)
    case newTopic
    case rename(CourseSummary)

    var id: String {
        switch self {
        case .newCourse(let semester): "course.\(semester.id)"
        case .newTopic: "topic"
        case .rename(let course): "rename.\(course.id)"
        }
    }
}

/// The iPad's course column before she chooses a course, as when she has none or opened none yet.
private struct NoCourseChosen: View {
    /// Nil while the courses load.
    let hasCourses: Bool?

    var body: some View {
        VStack(spacing: QBankSpacing.space3) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.qbank(.text4))
                .padding(.bottom, QBankSpacing.space2)
                .accessibilityHidden(true)
            if let hasCourses {
                Text(hasCourses ? "Choose a course" : "No courses yet")
                    .qbankFont(.title3)
                    .foregroundStyle(.qbank(.text1))
                Text(hasCourses
                    ? "Its pages, folders, Review and Terms open here."
                    : "Tap + to add one, or import its first question file.")
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(QBankSpacing.gutterTablet)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qbankScreenBackground()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.noCourse")
    }
}

/// A course on Home: code, title, size, what is waiting in Review, and how much she has answered.
/// A topic's card has its name alone, without a code. Shown from the phone's copy, it says how old
/// the copy is instead of the Review count.
struct CourseCard: View {
    let course: CourseSummary
    var savedAt: Date?
    /// In the iPad's sidebar, the badge goes under the size, which then fits on one line.
    var isNarrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: QBankSpacing.space1) {
            if course.kind != .topic {
                Text(course.code)
                    .qbankFont(.caption1)
                    .foregroundStyle(.qbank(.text3))
            }
            Text(course.title)
                .qbankFont(.headline)
                .foregroundStyle(.qbank(.text1))
                .multilineTextAlignment(.leading)
            let line = isNarrow
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: QBankSpacing.space3))
                : AnyLayout(HStackLayout(alignment: .center, spacing: QBankSpacing.space3))
            line {
                Text(Wording.size(questions: course.questionCount, folders: course.folderCount))
                    .qbankFont(.subheadline)
                    .foregroundStyle(.qbank(.text2))
                if !isNarrow {
                    Spacer(minLength: 0)
                }
                if let savedAt {
                    SavedBadge(date: savedAt)
                } else if course.reviewCount > 0 {
                    QBankTintedLabel("\(course.reviewCount) to review", systemImage: "tray", tone: .tint, size: .small)
                }
            }
            .padding(.top, QBankSpacing.space2)
            QBankProgressPill(value: Double(Wording.answeredPercent(course)) / 100)
                .padding(.top, QBankSpacing.space3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
