import Foundation
import Observation
import QBankKit

/// Something she can delete: a set (a practice set, or an exam set of a folder's exam bank), a
/// folder with every set in it, a page alone, one of her past exams,
/// or a course or study topic with everything in it, called by its name (a course's code, a topic's
/// title).
enum DeleteTarget: Hashable {
    case set(id: String, title: String)
    case folder(id: String, name: String)
    /// Its folders stay in the course, on no page, with their sets, until Undo puts them back on it.
    case examPage(id: String, name: String)
    case exam(id: String)
    case course(id: String, name: String)

    /// Brings it back as it was, within its 30 days.
    func undo(with client: QBankClient) async throws(QBankError) {
        switch self {
        case .set(let id, _): try await client.undoDeletePracticeSet(id: id)
        case .folder(let id, _): try await client.undoDeleteFolder(id: id)
        case .examPage(let id, _): _ = try await client.undoDeleteCourseExam(id: id)
        case .exam(let id): try await client.undoDeleteExam(id: id)
        case .course(let id, _): try await client.undoDeleteCourse(id: id)
        }
    }
}

/// A delete she asked for, while its warning is open.
struct DeleteRequest: Identifiable {
    let id = UUID()
    let target: DeleteTarget
}

/// The lines a delete shows, around the server's own warning.
nonisolated enum DeleteWording {
    /// The confirmation's title and message: the server's `warning`, its question ("Delete Week 1?")
    /// and the rest, what goes with it and Undo. A server before `warning` sent only `message`,
    /// which is split here instead.
    static func shown(_ preview: some DeletionPreview) -> (title: String, message: String)? {
        if let warning = preview.warning { return (warning.title, warning.body) }
        return split(preview.message)
    }

    /// The warning split at its first question, for a server that sends no `warning`.
    static func split(_ message: String) -> (title: String, message: String)? {
        guard let end = message.range(of: "? ") else { return nil }
        let title = String(message[..<end.lowerBound]) + "?"
        let rest = message[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : (title, rest)
    }

    /// The confirmation's title before the warning arrives: "Delete Week 1?", "Delete Exam 2?",
    /// "Delete this exam?", "Delete NURS 220?".
    static func question(_ target: DeleteTarget) -> String {
        switch target {
        case .set(_, let title): "Delete \(title)?"
        case .folder(_, let name), .examPage(_, let name), .course(_, let name): "Delete \(name)?"
        case .exam: "Delete this exam?"
        }
    }

    /// The Undo bar's line once it is deleted: "Heart B deleted.", "Week 1 and its 3 sets deleted.",
    /// "Exam 2 deleted." (its folders stayed), "Exam deleted.", "NURS 220 deleted."
    static func deleted(_ target: DeleteTarget, setCount: Int = 0) -> String {
        switch target {
        case .set(_, let title): "\(title) deleted."
        case .folder(_, let name): "\(name)\(withSets(setCount)) deleted."
        case .exam: "Exam deleted."
        case .examPage(_, let name), .course(_, let name): "\(name) deleted."
        }
    }

    /// The Undo bar's lines for several sets: "2 sets deleted." and "2 sets are back."
    static func deleted(setCount: Int) -> String { "\(Wording.count(setCount, "set")) deleted." }
    static func back(setCount: Int) -> String { "\(Wording.count(setCount, "set")) are back." }

    /// The Undo bar's line once Undo brought it back: "Heart B is back.", "Week 1 and its 3 sets
    /// are back.", "Exam 2 is back.", "NURS 220 is back."
    static func back(_ target: DeleteTarget, setCount: Int = 0) -> String {
        switch target {
        case .set(_, let title): "\(title) is back."
        case .folder(_, let name): setCount == 0 ? "\(name) is back." : "\(name)\(withSets(setCount)) are back."
        case .exam: "The exam is back."
        case .examPage(_, let name), .course(_, let name): "\(name) is back."
        }
    }

    private static func withSets(_ count: Int) -> String {
        switch count {
        case 0: ""
        case 1: " and its set"
        default: " and its \(Wording.count(count, "set"))"
        }
    }
}

/// One delete, from its warning to its end: reads what goes, shows it as the server words it, and
/// deletes exactly that with the preview's `confirm`. When what goes changed since the warning,
/// nothing is deleted: it reads the warning again and says why, so she confirms what goes now.
@Observable
final class DeleteModel {
    /// The warning, as the confirmation shows it.
    struct Warning: Equatable {
        let title: String
        let message: String
        /// Why it cannot be deleted right now, in the server's words; Delete waits while it is set.
        let refusal: String?
        let confirm: String
        /// What the Undo bar says once it is deleted, and once Undo brought it back.
        let deleted: String
        let back: String
    }

    let target: DeleteTarget
    private(set) var warning: Warning?
    private(set) var isDeleting = false
    /// What went wrong, in the server's words when it sent some.
    private(set) var problem: String?

    private let app: AppModel

    init(app: AppModel, target: DeleteTarget) {
        self.app = app
        self.target = target
    }

    /// The title before the warning arrives, then the warning's own question.
    var title: String {
        warning?.title ?? DeleteWording.question(target)
    }

    var canDelete: Bool {
        warning != nil && warning?.refusal == nil && !isDeleting
    }

    /// Reads what deleting it takes.
    func load() async {
        do {
            warning = try await preview()
            problem = nil
        } catch {
            report(error)
        }
    }

    /// Deletes what the warning named and offers Undo. True once it is deleted.
    func delete() async -> Bool {
        guard let warning, canDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await send(confirm: warning.confirm)
        } catch {
            if error.serverCode == .deletionChanged {
                // What goes is not what she was warned of: she reads it again before anything goes.
                do {
                    self.warning = try await preview()
                } catch let again {
                    report(again)
                    return false
                }
            }
            report(error)
            return false
        }
        problem = nil
        app.deletions.deleted(target, line: warning.deleted, back: warning.back)
        return true
    }

    private func preview() async throws(QBankError) -> Warning {
        let preview: any DeletionPreview
        var setCount = 0
        switch target {
        case .set(let id, _):
            preview = try await app.client.practiceSetDeletion(id: id)
        case .folder(let id, _):
            let folder = try await app.client.folderDeletion(id: id)
            setCount = folder.setCount
            preview = folder
        case .examPage(let id, _):
            preview = try await app.client.courseExamDeletion(id: id)
        case .exam(let id):
            preview = try await app.client.examDeletion(id: id)
        case .course(let id, _):
            preview = try await app.client.courseDeletion(id: id)
        }
        let shown = DeleteWording.shown(preview)
        return Warning(
            title: shown?.title ?? DeleteWording.question(target),
            message: shown?.message ?? preview.message,
            refusal: preview.refusal,
            confirm: preview.confirm,
            deleted: DeleteWording.deleted(target, setCount: setCount),
            back: DeleteWording.back(target, setCount: setCount)
        )
    }

    private func send(confirm: String) async throws(QBankError) {
        switch target {
        case .set(let id, _): try await app.client.deletePracticeSet(id: id, confirm: confirm)
        case .folder(let id, _): try await app.client.deleteFolder(id: id, confirm: confirm)
        case .examPage(let id, _): try await app.client.deleteCourseExam(id: id, confirm: confirm)
        case .exam(let id): try await app.client.deleteExam(id: id, confirm: confirm)
        case .course(let id, _): try await app.client.deleteCourse(id: id, confirm: confirm)
        }
    }

    private func report(_ error: QBankError) {
        guard !app.handle(error) else { return }
        problem = Wording.problem(error) ?? "Something went wrong. Try again."
    }
}

/// The sets she ticked in a folder, from one warning: each set's preview says what goes, and Delete
/// sends each preview's `confirm`, so exactly what she read goes. A refusal stops it where it is, and
/// what is left is read again, so she sees what is true now. Undo covers every set this deleted, also
/// when a refusal stopped it partway and she then closed the sheet.
@Observable
final class DeleteSetsModel {
    /// What is still to delete: after a refusal partway through, the sets that went are left out.
    private(set) var left: [PracticeSetSummary]
    private(set) var previews: [SetDeletion]?
    private(set) var isDeleting = false
    private var loadProblem: String?
    private var deleteProblem: String?
    /// What this has deleted so far, for the one Undo it offers.
    private var gone: [PracticeSetSummary] = []

    private let app: AppModel

    init(app: AppModel, sets: [PracticeSetSummary]) {
        self.app = app
        left = sets
    }

    private var only: (title: String, message: String)? {
        guard left.count == 1, previews?.count == 1, let preview = previews?.first else { return nil }
        return DeleteWording.shown(preview)
    }

    /// One set's warning's question, or "Delete 2 sets?".
    var title: String {
        if let only { return only.title }
        if left.count == 1, let set = left.first { return DeleteWording.question(.set(id: set.id, title: set.title)) }
        return "Delete \(Wording.count(left.count, "set"))?"
    }

    /// One set's warning, or each set's own, in the server's words.
    var message: String {
        only?.message ?? previews?.map(\.message).joined(separator: "\n\n") ?? ""
    }

    /// What went wrong and why any set cannot be deleted right now, each said once.
    var problem: String? {
        let lines = [deleteProblem, loadProblem].compactMap(\.self) + (previews ?? []).compactMap(\.refusal)
        let said = lines.reduce(into: [String]()) { said, line in
            if !said.contains(line) { said.append(line) }
        }
        return said.isEmpty ? nil : said.joined(separator: "\n")
    }

    var isLoading: Bool {
        previews == nil && loadProblem == nil
    }

    var canDelete: Bool {
        previews != nil && !isDeleting && (previews ?? []).allSatisfy { $0.refusal == nil }
    }

    /// Reads what deleting each set takes.
    func load() async {
        do {
            var read: [SetDeletion] = []
            for set in left {
                read.append(try await app.client.practiceSetDeletion(id: set.id))
            }
            previews = read
            loadProblem = nil
        } catch {
            if !app.handle(error) {
                loadProblem = Wording.problem(error) ?? "Something went wrong. Try again."
            }
        }
    }

    /// Deletes what the warning named and offers Undo. True once every set is deleted.
    func delete() async -> Bool {
        guard let previews, canDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }
        deleteProblem = nil
        for (set, preview) in zip(left, previews) {
            do {
                try await app.client.deletePracticeSet(id: set.id, confirm: preview.confirm)
                gone.append(set)
            } catch {
                await refused(error)
                return false
            }
        }
        offerUndo()
        return true
    }

    /// Undo for what went, once the sheet closes after a refusal. Offered once.
    func offerUndo() {
        guard !gone.isEmpty else { return }
        let targets = gone.map { DeleteTarget.set(id: $0.id, title: $0.title) }
        if let only = targets.first, targets.count == 1 {
            app.deletions.deleted(only, line: DeleteWording.deleted(only), back: DeleteWording.back(only))
        } else {
            app.deletions.deleted(targets, line: DeleteWording.deleted(setCount: targets.count), back: DeleteWording.back(setCount: targets.count))
        }
        gone = []
    }

    /// The screen underneath shows what went, and what is left is read again.
    private func refused(_ error: QBankError) async {
        if !gone.isEmpty { app.deletions.changed() }
        guard !app.handle(error) else { return }
        deleteProblem = Wording.problem(error) ?? "Something went wrong. Try again."
        let went = Set(gone.map(\.id))
        left.removeAll { went.contains($0.id) }
        previews = nil
        await load()
    }
}

/// The app's last delete, offered for Undo in a bar at the bottom of Home for a few seconds, and
/// a count the screens follow so they read again after a delete or an Undo.
@Observable
final class Deletions {
    struct Offer: Identifiable, Equatable {
        enum State: Equatable {
            case offered
            case undoing
            /// Brought back: the line says so.
            case undone
            /// Undo was refused, in the server's words.
            case failed(String)
        }

        let id = UUID()
        /// What it deleted, more than one for sets ticked together; Undo brings the last back first,
        /// so each goes back in its place.
        let targets: [DeleteTarget]
        let line: String
        let back: String
        var state = State.offered
    }

    private(set) var offer: Offer?
    /// Counts each delete and each Undo, so the screens that list what changed read it again.
    private(set) var revision = 0

    /// It was deleted: Undo is offered at once.
    func deleted(_ target: DeleteTarget, line: String, back: String) {
        deleted([target], line: line, back: back)
    }

    func deleted(_ targets: [DeleteTarget], line: String, back: String) {
        offer = Offer(targets: targets, line: line, back: back)
        revision += 1
    }

    /// Some of what she asked to delete went before a refusal: the screens read it again, and Undo
    /// comes once the sheet closes.
    func changed() {
        revision += 1
    }

    /// Undo from the bar.
    func undo(with app: AppModel) async {
        guard var offer, offer.state == .offered else { return }
        offer.state = .undoing
        self.offer = offer
        var isAnyBack = false
        do {
            for target in offer.targets.reversed() {
                try await target.undo(with: app.client)
                isAnyBack = true
            }
            offer.state = .undone
            revision += 1
        } catch {
            if app.handle(error) {
                self.offer = nil
                return
            }
            if isAnyBack { revision += 1 }
            offer.state = .failed(Wording.problem(error) ?? "Something went wrong. Try again.")
        }
        // Only the bar still showing this delete changes.
        if self.offer?.id == offer.id { self.offer = offer }
    }

    /// Brought back from Recently deleted: the bar about it, if still showing, goes.
    func broughtBack(_ target: DeleteTarget) {
        if offer?.targets.contains(target) == true { offer = nil }
        revision += 1
    }

    func dismiss(_ id: UUID) {
        if offer?.id == id { offer = nil }
    }
}
