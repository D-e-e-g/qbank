import Foundation
import Observation
import QBankKit

/// A course's Recently deleted: the pages, folders and sets she deleted and her past exams she
/// deleted, in the last 30 days, newest first, each with Bring back until its days run out.
@Observable
final class RecentlyDeletedModel {
    let courseID: String
    /// Nil until the first load answers.
    private(set) var deleted: RecentlyDeleted?
    private(set) var loadProblem: String?
    /// The item being brought back.
    private(set) var bringingBack: DeleteTarget?
    private(set) var problem: String?
    /// What came back last, said once it is back.
    private(set) var back: String?

    private let app: AppModel

    init(app: AppModel, courseID: String) {
        self.app = app
        self.courseID = courseID
    }

    var needsConnection: Bool {
        !app.connection.isOnline
    }

    func load() async {
        do {
            deleted = try await app.client.recentlyDeleted(courseID: courseID)
            loadProblem = nil
        } catch {
            if app.handle(error) { return }
            // A list already shown stays; only a first load says what went wrong.
            if deleted == nil {
                loadProblem = Wording.problem(error)
            }
        }
    }

    /// Brings one back as it was, then reads the list again.
    func bringBack(_ target: DeleteTarget, saying line: String) async {
        guard !app.frozen.refuses(), bringingBack == nil else { return }
        bringingBack = target
        problem = nil
        back = nil
        defer { bringingBack = nil }
        do {
            try await target.undo(with: app.client)
            back = line
            app.deletions.broughtBack(target)
        } catch {
            if app.handle(error) { return }
            problem = Wording.problem(error)
        }
        await load()
    }
}

/// The lines Recently deleted shows, worded as the rest of the app words them.
nonisolated enum RecentlyDeletedWording {
    /// An exam page's line: the folders Bring back puts back on it, "Week 3, Week 4", the first two
    /// and how many more past three ("Week 1, Week 2 and 3 more"), or "No folders".
    static func folders(_ page: DeletedExamPage) -> String {
        let names = page.folders.map(\.name)
        guard !names.isEmpty else { return "No folders" }
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
    }

    /// A folder's line: its sets by name, "Heart A, Heart B and Heart A exam", or "No sets".
    static func sets(_ folder: DeletedFolder) -> String {
        guard !folder.sets.isEmpty else { return "No sets" }
        return listText(folder.sets.map(\.title))
    }

    /// A set's line: "Week 2 · 3 questions", or "Week 1 · exam bank · 3 questions".
    static func set(_ set: DeletedSet) -> String {
        let place = set.folderName.isEmpty ? [] : [set.folderName]
        let bank = set.kind == .exam ? ["exam bank"] : []
        return (place + bank + [Wording.count(set.questionCount, "question")]).joined(separator: " · ")
    }

    /// When it went and until when Undo can bring it back: "Deleted today · until Nov 17".
    static func window(deletedAt: Date, undoUntil: Date, now: Date = .now) -> String {
        "Deleted \(Wording.when(deletedAt, now: now)) · until \(undoUntil.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "Heart A", "Heart A and Heart B", "Heart A, Heart B and Heart C", as the server lists them.
    static func listText(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.joined() }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }
}
