#if DEBUG
import Foundation
import QBankKit

/// What the fake server's deletes read through it: her sets' titles, sizes and answers, and a
/// folder as a reply draws it.
nonisolated extension FakeQBankServer: FakeDeletionLibrary {
    /// The invented exam banks' titles, by the start of their questions' ids.
    private static let examBanks = ["bank1": "Rights and Communication Exam", "bank3": "Depression and Anxiety Exam"]

    func deletionSet(_ id: String) -> (title: String, questionCount: Int, answeredCount: Int, versionCount: Int)? {
        guard let entry = summary(of: id) else { return nil }
        let answered = set(id)["answeredCount"] as? Int ?? 0
        return (entry.title, entry.questions, answered, entry.canRestore ? 2 : 1)
    }

    func examSetTitle(_ id: String) -> String {
        Self.examBanks[id] ?? summary(of: id)?.title ?? "Exam set"
    }

    func folderReply(_ folder: FakeStudy.Folder) -> [String: Any] {
        folderJSON(folder)
    }
}

/// What Make questions and exam twins read and file through the fake server: her courses, folders
/// and sets, and the sets they file, as an import files them.
nonisolated extension FakeQBankServer: FakeQuestionLibrary {
    func makerCourse(_ id: String) -> (code: String, title: String)? {
        state.withLock { state in state.courses.first { $0.id == id && $0.archivedAt == nil && $0.deletedAt == nil }.map { ($0.code, $0.title) } }
    }

    func makerFolderName(courseID: String, folderID: String) -> String? {
        study.folders(courseID).first { $0.id == folderID }?.name
    }

    func makerSetTitle(_ id: String) -> String? {
        summary(of: id)?.title
    }

    func fileMadeSet(
        courseID: String, folderID: String?, folderName: String, title: String, questionCount: Int, termCount: Int, examTwins: Int
    ) -> FakeQuestionMaker.Filed? {
        let named = folderID == nil && folderName != "Unsorted" ? folderName : nil
        guard case .success(let folder) = study.importFolder(courseID: courseID, folderID: folderID, folderName: named) else { return nil }
        let (setID, examID) = state.withLock { state -> (String, String?) in
            state.importCount += 1
            let setID = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            state.imported[setID] = ImportedEntry(
                courseID: courseID, title: title, kind: "practice", questionCount: questionCount, termCount: termCount,
                importedAt: .now, status: "imported", previous: nil
            )
            guard examTwins > 0 else { return (setID, nil) }
            state.importCount += 1
            let examID = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            state.imported[examID] = ImportedEntry(
                courseID: courseID, title: "\(title) exam", kind: "exam", questionCount: examTwins, termCount: 0,
                importedAt: .now, status: "imported", previous: nil
            )
            return (setID, examID)
        }
        study.file(set: setID, in: folder.id, replacing: nil, questionCount: questionCount)
        if let examID { study.file(bank: FakeStudy.ids("bank-\(examID)", examTwins), in: folder.id) }
        return FakeQuestionMaker.Filed(setID: setID, folderID: folder.id, folderName: folder.name, examPageID: folder.examPageID, examSetID: examID)
    }

    func fileTwinSet(courseID: String, folderID: String, title: String, questionCount: Int) -> (setID: String, examPageID: String?) {
        let setID = state.withLock { state -> String in
            state.importCount += 1
            let setID = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            state.imported[setID] = ImportedEntry(
                courseID: courseID, title: title, kind: "exam", questionCount: questionCount, termCount: 0,
                importedAt: .now, status: "imported", previous: nil
            )
            return setID
        }
        return (setID, study.folders(courseID).first { $0.id == folderID }?.examPageID)
    }
}
#endif
