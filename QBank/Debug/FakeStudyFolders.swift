#if DEBUG
import Foundation
import QBankKit
import Synchronization

/// The fake server's folders and exam pages, and where an import files its sets, with the real
/// server's rules and words.
nonisolated extension FakeStudy {
    // MARK: Import, with the rules of `content/service.ts` `commitImport`

    /// The folder holding a current practice set.
    func folder(holding setID: String) -> Folder? {
        state.withLock { state in state.folders.first { $0.sets.contains(setID) } }
    }

    /// The folder an import files a set under: the one she picked, the one she named (the course's
    /// folder of that name on no exam page, else its only folder of that name, else a new one at the
    /// end of its Folders list), or Unsorted, made at the top of the Folders list the first time.
    func importFolder(courseID: String, folderID: String?, folderName: String?) -> Result<Folder, Failure> {
        state.withLock { state in
            if let folderID {
                guard let folder = state.folders.first(where: { $0.id == folderID && $0.courseID == courseID }) else {
                    return .failure(Failure(status: 400, message: "That folder is not in this course."))
                }
                return .success(folder)
            }
            if let folderName {
                let named = state.folders.filter { $0.courseID == courseID && $0.name.lowercased() == folderName.lowercased() }
                if let loose = named.first(where: { $0.examPageID == nil }) { return .success(loose) }
                if named.count == 1 { return .success(named[0]) }
                return .success(Self.newFolder(folderName, courseID: courseID, page: nil, in: &state))
            }
            if let unsorted = state.folders.first(where: { $0.courseID == courseID && $0.examPageID == nil && $0.name == "Unsorted" }) {
                return .success(unsorted)
            }
            let top = (state.folders.filter { $0.courseID == courseID && $0.examPageID == nil }.map(\.sortOrder).min() ?? 1) - 1
            var unsorted = Self.newFolder("Unsorted", courseID: courseID, page: nil, in: &state)
            unsorted.sortOrder = top
            state.folders[state.folders.count - 1] = unsorted
            return .success(unsorted)
        }
    }

    /// Files a new practice set in a folder, or with `replacing`, in that set's place.
    func file(set id: String, in folderID: String, replacing old: String?, questionCount: Int) {
        state.withLock { state in
            state.sizes[id] = questionCount
            if let old, let index = state.folders.firstIndex(where: { $0.sets.contains(old) }) {
                state.folders[index].sets = state.folders[index].sets.map { $0 == old ? id : $0 }
            } else if let index = state.folders.firstIndex(where: { $0.id == folderID }) {
                state.folders[index].sets.append(id)
            }
        }
    }

    /// Files an exam set's questions in a folder's exam bank.
    func file(bank questionIDs: [String], in folderID: String) {
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == folderID }) else { return }
            state.folders[index].bank += questionIDs
        }
    }

    // MARK: Folders and exam pages, with the rules and words of `content/folders.ts`

    /// A refusal, in the server's words.
    struct Failure: Error {
        let status: Int
        let message: String

        var reply: Reply { FakeStudy.failure(status, "request_refused", message) }
    }

    static func reply(_ result: Result<Folder, Failure>, status: Int, _ folderJSON: (Folder) -> [String: Any]) -> Reply {
        switch result {
        case .success(let folder): (status, folderJSON(folder))
        case .failure(let failure): failure.reply
        }
    }

    /// A required name, trimmed: refused when blank or longer than 80 characters.
    private static func requiredText(_ value: Any?, label: String) -> Result<String, Failure> {
        let text = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(Failure(status: 400, message: "\(label) is required.")) }
        if text.count > 80 { return .failure(Failure(status: 400, message: "\(label) is too long.")) }
        return .success(text)
    }

    /// A list as a refusal names it: the exam page, or the course for its Folders list.
    private static func listLabel(_ page: String?, courseID: String, in state: State) -> String {
        page.flatMap { page in state.courseExams.first { $0.id == page }?.name } ?? codes[courseID] ?? "This course"
    }

    /// Refuses a name another folder of the list already has, ignoring case.
    static func nameTaken(_ name: String, courseID: String, page: String?, except ids: Set<String>, in state: State) -> Failure? {
        let clash = state.folders.first {
            $0.courseID == courseID && $0.examPageID == page && !ids.contains($0.id) && $0.name.lowercased() == name.lowercased()
        }
        return clash.map { Failure(status: 409, message: "\(listLabel(page, courseID: courseID, in: state)) already has a folder named \($0.name).") }
    }

    /// The exam page a folder may go on: one of its course's.
    private static func page(_ id: String, courseID: String, in state: State) -> Failure? {
        state.courseExams.contains { $0.id == id && $0.courseID == courseID } ? nil : Failure(status: 400, message: "That exam page is not in this course.")
    }

    /// The next place at the end of a list.
    static func end(of page: String?, courseID: String, in state: State) -> Int {
        (state.folders.filter { $0.courseID == courseID && $0.examPageID == page }.map(\.sortOrder).max() ?? 0) + 1
    }

    private static func newFolder(_ name: String, courseID: String, page: String?, in state: inout State) -> Folder {
        state.folderCount += 1
        let folder = Folder(
            id: String(format: "f0000000-0000-4000-8000-%012d", 9000 + state.folderCount), courseID: courseID, name: name,
            examPageID: page, sortOrder: end(of: page, courseID: courseID, in: state), sets: [], bank: []
        )
        state.folders.append(folder)
        return folder
    }

    func createFolder(courseID: String, body: [String: Any]) -> Result<Folder, Failure> {
        state.withLock { state in
            let name: String
            switch Self.requiredText(body["name"], label: "Folder name") {
            case .success(let text): name = text
            case .failure(let failure): return .failure(failure)
            }
            let page = body["examPageId"] as? String
            if let page, let failure = Self.page(page, courseID: courseID, in: state) { return .failure(failure) }
            if let failure = Self.nameTaken(name, courseID: courseID, page: page, except: [], in: state) { return .failure(failure) }
            return .success(Self.newFolder(name, courseID: courseID, page: page, in: &state))
        }
    }

    /// Renames a folder, puts it on an exam page, or takes it off one. A folder that changes list
    /// goes to the end of its new list.
    func changeFolder(id: String, body: [String: Any]) -> Result<Folder, Failure> {
        state.withLock { state in
            guard let index = state.folders.firstIndex(where: { $0.id == id }) else {
                return .failure(Failure(status: 404, message: "That folder is not in the app."))
            }
            let folder = state.folders[index]
            var name = folder.name
            if body.keys.contains("name") {
                switch Self.requiredText(body["name"], label: "Folder name") {
                case .success(let text): name = text
                case .failure(let failure): return .failure(failure)
                }
            }
            let page = body.keys.contains("examPageId") ? body["examPageId"] as? String : folder.examPageID
            if let page, let failure = Self.page(page, courseID: folder.courseID, in: state) { return .failure(failure) }
            if let failure = Self.nameTaken(name, courseID: folder.courseID, page: page, except: [id], in: state) { return .failure(failure) }
            if page != folder.examPageID {
                state.folders[index].sortOrder = Self.end(of: page, courseID: folder.courseID, in: state)
                state.folders[index].examPageID = page
            }
            state.folders[index].name = name
            return .success(state.folders[index])
        }
    }

    /// Moves a set to a folder of its course, or to a new one at the end of the Folders list.
    func moveSet(id: String, body: [String: Any]) -> Result<Folder, Failure> {
        state.withLock { state in
            guard let from = state.folders.firstIndex(where: { $0.sets.contains(id) }) else {
                return .failure(Failure(status: 404, message: "That set is not in the app."))
            }
            let courseID = state.folders[from].courseID
            let folderID = body["folderId"] as? String, newName = body["newFolderName"]
            if folderID != nil, newName != nil { return .failure(Failure(status: 400, message: "Choose a folder or a new folder name, not both.")) }
            let to: Int
            if let folderID {
                guard let index = state.folders.firstIndex(where: { $0.id == folderID && $0.courseID == courseID }) else {
                    return .failure(Failure(status: 400, message: "That folder is not in this course."))
                }
                to = index
            } else if newName != nil {
                let name: String
                switch Self.requiredText(newName, label: "Folder name") {
                case .success(let text): name = text
                case .failure(let failure): return .failure(failure)
                }
                if let failure = Self.nameTaken(name, courseID: courseID, page: nil, except: [], in: state) { return .failure(failure) }
                _ = Self.newFolder(name, courseID: courseID, page: nil, in: &state)
                to = state.folders.count - 1
            } else {
                return .failure(Failure(status: 400, message: "Choose a folder to move it to."))
            }
            if to != from {
                state.folders[from].sets.removeAll { $0 == id }
                state.folders[to].sets.append(id)
            }
            return .success(state.folders[to])
        }
    }

    /// Saves her order of one list. A list that does not name exactly its folders is refused.
    func reorder(courseID: String, body: [String: Any], _ folderJSON: (Folder) -> [String: Any]) -> Reply {
        let result = state.withLock { state -> Result<[Folder], Failure> in
            let page = body["examPageId"] as? String
            if let page, let failure = Self.page(page, courseID: courseID, in: state) { return .failure(failure) }
            let ids = body["folderIds"] as? [String] ?? []
            let list = state.folders.filter { $0.courseID == courseID && $0.examPageID == page }.map(\.id)
            guard ids.count == list.count, Set(ids) == Set(list) else {
                return .failure(Failure(status: 409, message: "The folders changed since this list was shown. Reload and try again."))
            }
            for (position, id) in ids.enumerated() {
                if let index = state.folders.firstIndex(where: { $0.id == id }) { state.folders[index].sortOrder = position + 1 }
            }
            return .success(ids.compactMap { id in state.folders.first { $0.id == id } })
        }
        switch result {
        case .success(let folders): return (200, ["folders": folders.map(folderJSON)])
        case .failure(let failure): return failure.reply
        }
    }

    /// Adds an exam page or renames one and sets its folders, in the order sent. Folders it gives
    /// up go to the end of the Folders list.
    func saveCourseExam(courseID givenCourse: String?, id: String?, body: [String: Any]) -> Reply {
        state.withLock { state -> Reply in
            let courseID: String
            if let id {
                guard let page = state.courseExams.first(where: { $0.id == id }) else {
                    return Self.failure(404, "request_refused", "That exam is not in the app.")
                }
                courseID = page.courseID
            } else {
                courseID = givenCourse ?? ""
            }
            let name: String
            switch Self.requiredText(body["name"], label: "Exam name") {
            case .success(let text): name = text
            case .failure(let failure): return failure.reply
            }
            if state.courseExams.contains(where: { $0.courseID == courseID && $0.id != id && $0.name.lowercased() == name.lowercased() }) {
                return Self.failure(409, "request_refused", "This course already has an exam named \(name).")
            }
            // Null or empty takes the link off; left out, a page keeps its link.
            let link: String??
            switch body["linkUrl"] {
            case nil: link = .none
            case let text as String where !text.trimmingCharacters(in: .whitespaces).isEmpty:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let scheme = URL(string: trimmed)?.scheme?.lowercased()
                guard trimmed.count <= 2000, scheme == "http" || scheme == "https", URL(string: trimmed)?.host() != nil else {
                    return Self.failure(400, "request_refused", "A link has to be a web address, such as https://example.com/primer.")
                }
                link = .some(trimmed)
            default: link = .some(nil)
            }
            // Null takes the badge off; left out, a page keeps it, and a new page has none.
            let badge: String??
            switch body["badge"] {
            case nil: badge = .none
            case let value as String where ["exam", "concept", "study"].contains(value): badge = .some(value)
            case is NSNull: badge = .some(nil)
            default: return Self.failure(400, "invalid_request", "That badge is not one QBank knows.")
            }
            let sent = body["folderIds"] as? [String]
            var target: [Folder] = []
            for folderID in sent ?? [] where !target.contains(where: { $0.id == folderID }) {
                guard let folder = state.folders.first(where: { $0.id == folderID && $0.courseID == courseID }) else {
                    let missing = Set(sent ?? []).count { folderID in !state.folders.contains { $0.id == folderID && $0.courseID == courseID } }
                    return Self.failure(400, "request_refused", missing == 1 ? "That folder is not in this course." : "Those folders are not in this course.")
                }
                target.append(folder)
            }
            // A folder of another page is refused, naming the page that has it.
            var held: [(page: String, names: [String])] = []
            for folder in target {
                guard let holder = folder.examPageID, holder != id else { continue }
                let pageName = state.courseExams.first { $0.id == holder }?.name ?? "another exam page"
                if let index = held.firstIndex(where: { $0.page == pageName }) { held[index].names.append(folder.name) } else { held.append((pageName, [folder.name])) }
            }
            if !held.isEmpty {
                return Self.failure(409, "request_refused", held.map { "\(Self.listText($0.names)) \($0.names.count == 1 ? "is" : "are") in \($0.page)." }.joined(separator: " "))
            }
            for (index, folder) in target.enumerated() {
                if let clash = target.prefix(index).first(where: { $0.name.lowercased() == folder.name.lowercased() }) {
                    return Self.failure(409, "request_refused", "\(name) already has a folder named \(clash.name).")
                }
            }
            let keep = Set(target.map(\.id))
            let leaving = id.map { id in Self.ordered(state, courseID: courseID).filter { $0.examPageID == id && !keep.contains($0.id) } } ?? []
            if sent != nil {
                for folder in leaving {
                    if let failure = Self.nameTaken(folder.name, courseID: courseID, page: nil, except: keep.union([folder.id]), in: state) { return failure.reply }
                }
            }
            let page: CourseExam
            if let id, let index = state.courseExams.firstIndex(where: { $0.id == id }) {
                state.courseExams[index].name = name
                if let link { state.courseExams[index].linkURL = link }
                if let badge { state.courseExams[index].badge = badge }
                page = state.courseExams[index]
            } else {
                state.courseExamCount += 1
                page = CourseExam(
                    id: String(format: "c0e00000-0000-4000-8000-%012d", 100 + state.courseExamCount), courseID: courseID, name: name,
                    sortOrder: (state.courseExams.filter { $0.courseID == courseID }.map(\.sortOrder).max() ?? 0) + 1,
                    linkURL: link ?? nil, badge: badge ?? nil
                )
                state.courseExams.append(page)
            }
            // Without folderIds a page keeps its folders.
            if sent != nil {
                for folder in leaving {
                    guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                    state.folders[index].sortOrder = Self.end(of: nil, courseID: courseID, in: state)
                    state.folders[index].examPageID = nil
                }
                for (position, folder) in target.enumerated() {
                    guard let index = state.folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                    state.folders[index].examPageID = page.id
                    state.folders[index].sortOrder = position + 1
                }
            }
            return (id == nil ? 201 : 200, Self.pageJSON(page, in: state))
        }
    }
}
#endif
