import Foundation
import Observation
import QBankKit

/// Home: her semesters with their courses, her study topics, what she archived, what she deleted in
/// the last 30 days, and the course or topic she used last. Its + adds a semester, a course or a
/// topic, and holding a course or topic moves, archives or deletes it. Without a connection it shows
/// the copy saved on the phone, with her waiting answers counted in.
@Observable
final class HomeModel {
    /// What she archived by hand, under its semester or Study topics: an archived semester with
    /// every course of it, or the archived courses of a semester she still studies, or her
    /// archived topics.
    struct ArchivedGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let courses: [CourseSummary]
    }

    private(set) var catalog: Catalog?
    private(set) var isLoading = false
    private(set) var problem: String?
    /// Why adding a semester, moving or archiving was refused, in the server's words, until Home
    /// is read again.
    private(set) var editProblem: String?
    /// True while the + or a held card's menu waits for the server.
    private(set) var isEditing = false
    /// When the courses on screen were saved on the phone, or nil when they came from QBank just now.
    private(set) var savedAt: Date?
    /// The courses and topics she deleted that Bring back can still return, for Home's last row.
    /// Nil until read, and while Home shows the phone's copy.
    private(set) var recentlyDeleted: RecentlyDeletedCourses?
    /// Each course's saved copy, for its "Saved" badge and to count waiting answers into its card.
    private(set) var savedCourses: [String: Cached<CourseDetail>] = [:]
    private(set) var waitingProgress = WaitingProgress(answers: [:])

    private let app: AppModel
    /// Whether a user account is signed in, not the admin, as it was when Home was made. Home is
    /// made again for each sign-in, so it never changes; read live, it would change under the
    /// screens that signing out takes away, and keep them from going.
    private let isUserAccount: Bool

    init(app: AppModel) {
        self.app = app
        isUserAccount = app.account?.role == .student
    }

    /// Every semester, archived ones included. Nil until loaded.
    var semesters: [Semester]? {
        catalog?.semesters
    }

    /// The semesters Home lists, in number order: those she has not archived.
    var studiedSemesters: [Semester] {
        semesters?.filter { $0.archivedAt == nil } ?? []
    }

    /// The courses Home shows in a semester: archived ones are left out, the rest in the owner's
    /// order, with her waiting answers counted in.
    func courses(in semester: Semester) -> [CourseSummary] {
        Self.ordered(semester.courses.filter { $0.archivedAt == nil }).map(counted)
    }

    /// Her study topics in her order, without the archived ones, with her waiting answers counted in.
    var topics: [CourseSummary] {
        (catalog?.topics ?? []).filter { $0.archivedAt == nil }.map(counted)
    }

    /// What she archived, last on Home: each semester's, then her topics'. Empty when nothing is.
    var archived: [ArchivedGroup] {
        guard let catalog else { return [] }
        var groups: [ArchivedGroup] = []
        for semester in catalog.semesters {
            let courses = semester.archivedAt == nil ? semester.courses.filter { $0.archivedAt != nil } : semester.courses
            if semester.archivedAt != nil || !courses.isEmpty {
                groups.append(ArchivedGroup(id: semester.id, title: semester.name, courses: Self.ordered(courses).map(counted)))
            }
        }
        let topics = catalog.topics.filter { $0.archivedAt != nil }
        if !topics.isEmpty {
            groups.append(ArchivedGroup(id: "topics", title: "Study topics", courses: topics.map(counted)))
        }
        return groups
    }

    /// Adding, moving, archiving and deleting need QBank, so not from the copy on the phone. The
    /// controls look this way for the admin too, and answer with the frozen note.
    var offersEditing: Bool {
        savedAt == nil && app.connection.isOnline && !isEditing
    }

    /// Whether an edit may go to the server: only a user account changes what she has.
    var canEdit: Bool {
        isUserAccount && offersEditing
    }

    /// The semester the + adds, while one of 1, 2 and 3 is missing.
    var nextSemesterNumber: Int? {
        semesters.flatMap(CatalogModel.nextSemesterNumber(after:))
    }

    /// The semesters a course can move to: those she studies, but its own.
    func otherSemesters(than course: CourseSummary) -> [Semester] {
        studiedSemesters.filter { semester in !semester.courses.contains { $0.id == course.id } }
    }

    /// Whether a course or topic can be archived: one in use, but not a course of a semester she
    /// archived, which is in Archived with it; moving it to another semester brings it back.
    func canArchive(_ course: CourseSummary) -> Bool {
        guard course.archivedAt == nil else { return false }
        if course.kind == .topic { return true }
        return semesters?.first { semester in semester.courses.contains { $0.id == course.id } }?.archivedAt == nil
    }

    /// Whether a topic in use can move a place up (-1) or down (+1) among her topics in use.
    func canMove(_ topic: CourseSummary, by step: Int) -> Bool {
        guard let at = topics.firstIndex(where: { $0.id == topic.id }) else { return false }
        return topics.indices.contains(at + step)
    }

    /// A semester's courses in the owner's order.
    private static func ordered(_ courses: [CourseSummary]) -> [CourseSummary] {
        courses.sorted { ($0.sortOrder, $0.code) < ($1.sortOrder, $1.code) }
    }

    private func counted(_ course: CourseSummary) -> CourseSummary {
        waitingProgress.counting(course, saved: savedCourses[course.id]?.value)
    }

    /// The "Saved" badge of a course shown from the phone's copy: when its own copy was saved.
    func savedAt(_ course: CourseSummary) -> Date? {
        guard let savedAt else { return nil }
        return savedCourses[course.id]?.savedAt ?? savedAt
    }

    /// Loads the semesters. A failed reload keeps what is already on screen.
    func load() async {
        // Whose courses these are, read with them: the account can change on the web at any time.
        async let account: Void = app.frozen.readAccount(with: app.client)
        await loadCatalog()
        await account
    }

    private func loadCatalog() async {
        isLoading = true
        editProblem = nil
        defer { isLoading = false }
        do {
            let loaded = try await app.load(.catalog) { () async throws(QBankError) in try await app.client.catalog() }
            catalog = loaded.value
            savedAt = loaded.savedAt
            problem = nil
        } catch {
            guard !app.handle(error), let words = Wording.problem(error) else { return }
            problem = words
            return
        }
        await readSaved()
        await readDeleted()
    }

    /// What she deleted, for Home's last row. The list needs QBank, so the phone's copy has none; a
    /// failed read keeps the row as it was.
    private func readDeleted() async {
        guard savedAt == nil else {
            recentlyDeleted = nil
            return
        }
        if let deleted = try? await app.client.recentlyDeletedCourses() {
            recentlyDeleted = deleted
        }
    }

    /// Saves every course for offline in the background. `force` saves again even if it just did.
    func saveForOffline(force: Bool = false) {
        guard let catalog, savedAt == nil else { return }
        app.offline?.saveCourses(in: catalog, force: force)
    }

    /// The saved copies Home needs: for the badges when it shows the phone's copy, and to count
    /// waiting answers into the cards.
    private func readSaved() async {
        guard let offline = app.offline, savedAt != nil || !offline.waiting.isEmpty else {
            savedCourses = [:]
            waitingProgress = WaitingProgress(answers: [:])
            return
        }
        var saved: [String: Cached<CourseDetail>] = [:]
        for course in catalog?.everyCourse ?? [] {
            saved[course.id] = await offline.saved(.course(course.id))
        }
        savedCourses = saved
        waitingProgress = await offline.waitingProgress()
    }

    /// The course or topic to open on first arrival after sign-in, as on the web: the one she used
    /// last. Nil when she has none, when it was opened already, or for an admin, who has no study
    /// place.
    func landingCourse() async -> CourseRoute? {
        guard !app.hasLanded, app.account?.role == .student else { return nil }
        app.hasLanded = true
        guard savedAt == nil, let id = try? await app.client.studyPlace() else { return nil }
        let course = catalog?.course(id: id)
        return CourseRoute(id: id, name: course.map(Wording.name), kind: course?.kind ?? .course)
    }

    /// Reads the list again after she made a course or topic, which then opens.
    func made(_ course: CourseSummary) async -> CourseRoute {
        await load()
        return CourseRoute(id: course.id, name: Wording.name(course), kind: course.kind)
    }

    // MARK: Editing from Home

    /// Adds the next semester, from the + menu.
    func addSemester() async {
        guard let number = nextSemesterNumber else { return }
        await edit { () async throws(QBankError) in
            _ = try await app.client.addSemester(number: number)
        }
    }

    /// Archives a course or topic, which moves to Archived, or brings it back. Her answers stay.
    func setArchived(_ course: CourseSummary, _ archived: Bool) async {
        await edit { () async throws(QBankError) in
            _ = try await app.client.setCourseArchived(id: course.id, archived)
        }
    }

    /// Moves a course to another semester, with its folders, sets and her answers.
    func move(_ course: CourseSummary, to semester: Semester) async {
        await edit { () async throws(QBankError) in
            _ = try await app.client.updateCourse(id: course.id, code: course.code, title: course.title, semesterID: semester.id)
        }
    }

    /// Moves a topic a place up (-1) or down (+1) among her topics in use. The server takes every
    /// topic of hers, so the archived ones go after the others, in the order they had.
    func move(_ topic: CourseSummary, by step: Int) async {
        guard canMove(topic, by: step), let all = catalog?.topics else { return }
        var order = topics.map(\.id)
        guard let at = order.firstIndex(of: topic.id) else { return }
        order.swapAt(at, at + step)
        let archived = all.filter { $0.archivedAt != nil }.map(\.id)
        await edit { () async throws(QBankError) in
            _ = try await app.client.setTopicOrder(order + archived)
        }
    }

    /// Runs one edit, then reads the list again, whether or not it was saved.
    private func edit(_ change: () async throws(QBankError) -> Void) async {
        guard !app.frozen.refuses(), canEdit else { return }
        isEditing = true
        var failure: String?
        do {
            try await change()
        } catch {
            if !app.handle(error) {
                failure = Wording.problem(error) ?? "Something went wrong. Try again."
            }
        }
        await load()
        editProblem = failure
        isEditing = false
    }
}

/// A course or topic on the navigation stack. Its name, a course's code or a topic's title, shows
/// as the title before it loads.
struct CourseRoute: Hashable {
    let id: String
    let name: String?
    /// Picks the words its screen says while it loads, when known.
    var kind: CourseKind = .course
}
