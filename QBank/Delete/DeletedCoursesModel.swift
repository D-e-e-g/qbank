import Foundation
import Observation
import QBankKit

/// Home's Recently deleted: the courses and study topics she deleted in the last 30 days, newest
/// first, each with Bring back until its days run out.
@Observable
final class DeletedCoursesModel {
    /// Nil until the first load answers.
    private(set) var deleted: RecentlyDeletedCourses?
    private(set) var loadProblem: String?
    /// The course or topic being brought back.
    private(set) var bringingBack: DeleteTarget?
    private(set) var problem: String?
    /// What came back last, said once it is back.
    private(set) var back: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var needsConnection: Bool {
        !app.connection.isOnline
    }

    var courses: [DeletedCourse] {
        deleted?.courses.filter { $0.kind != .topic } ?? []
    }

    var topics: [DeletedCourse] {
        deleted?.courses.filter { $0.kind == .topic } ?? []
    }

    func load() async {
        do {
            deleted = try await app.client.recentlyDeletedCourses()
            loadProblem = nil
        } catch {
            if app.handle(error) { return }
            // A list already shown stays; only a first load says what went wrong.
            if deleted == nil {
                loadProblem = Wording.problem(error)
            }
        }
    }

    /// Brings one back whole, then reads the list again; Home reads its courses again too.
    func bringBack(_ course: DeletedCourse) async {
        guard !app.frozen.refuses(), bringingBack == nil else { return }
        let target = DeleteTarget.course(id: course.id, name: Wording.name(course))
        bringingBack = target
        problem = nil
        back = nil
        defer { bringingBack = nil }
        do {
            try await target.undo(with: app.client)
            back = DeleteWording.back(target)
            app.deletions.broughtBack(target)
        } catch {
            if app.handle(error) { return }
            problem = Wording.problem(error)
        }
        await load()
    }
}

/// The lines Home's Recently deleted shows for a course or topic.
nonisolated enum DeletedCoursesWording {
    /// What a row says under its name, a line each so none breaks beside Bring back: a course's
    /// title, its semester and its questions ("Fundamentals", "From Semester 2", "146 questions");
    /// a topic's questions alone.
    static func held(_ course: DeletedCourse) -> [String] {
        let questions = Wording.count(course.questionCount, "question")
        guard course.kind != .topic else { return [questions] }
        return [course.title] + (course.semester.map { ["From \($0.name)"] } ?? []) + [questions]
    }

    /// Home's last row, once she has deleted a course or topic: "2 items · Bring back for 30 days".
    static func entry(count: Int, undoDays: Int) -> String {
        "\(Wording.count(count, "item")) · Bring back for \(undoDays) days"
    }
}
