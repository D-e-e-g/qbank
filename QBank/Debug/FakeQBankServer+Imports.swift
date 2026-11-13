#if DEBUG
import Foundation
import QBankKit

/// Importing a set on the fake server, into a course, a new course or a new topic, and bringing
/// back the version a new one replaced.
nonisolated extension FakeQBankServer {
    // MARK: Import, with the rules and words of `content/service.ts` `commitImport`

    func importSet(_ body: [String: Any]) -> Reply {
        let source = body["source"] as? String ?? ""
        let check = FakeImportCheck(source: source)
        guard check.ok, let fileTitle = check.title else {
            return (400, [
                "error": "invalid_import", "message": check.errors.first ?? "This file can't be imported.",
                "errors": check.errors, "warnings": check.warnings,
            ])
        }
        var title = fileTitle
        if let given = body["title"] as? String {
            title = given.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return failure(400, "request_refused", "Set name is required.") }
        }
        let courseID = body["courseId"] as? String, newCourse = body["newCourse"] as? [String: Any]
        let newTopic = body["newTopic"] as? [String: Any]
        let folderID = body["folderId"] as? String
        let folderName = ((body["folderName"] ?? body["weekLabel"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = [courseID != nil, newCourse != nil, newTopic != nil].count { $0 }
        if chosen > 1 { return failure(400, "request_refused", "Choose a course, a new course or a new topic, not more than one.") }
        if chosen == 0 { return failure(400, "request_refused", "Choose a course.") }
        if folderID != nil, folderName != nil { return failure(400, "request_refused", "Choose a folder or a folder name, not both.") }
        if folderID != nil, newCourse != nil || newTopic != nil {
            return failure(400, "request_refused", "A new course has no folders yet. Name a folder, or leave it for Unsorted.")
        }
        if let folderName, folderName.isEmpty { return failure(400, "request_refused", "Folder name is required.") }
        let course: FakeCourse
        if let newCourse {
            switch makeCourse(newCourse) {
            case .success(let made): course = made
            case .failure(let refusal): return refusal.reply
            }
        } else if let newTopic {
            let (status, made) = addTopic(title: newTopic["title"] as? String ?? "")
            guard status == 201, let id = made["id"] as? String, let topic = state.withLock({ state in state.courses.first { $0.id == id } }) else {
                return (status, made)
            }
            course = topic
        } else if let known = state.withLock({ state in state.courses.first { $0.id == courseID && $0.deletedAt == nil } }) {
            course = known
        } else {
            return failure(404, "request_refused", "That course is not in the app.")
        }
        let decision = body["decision"] as? String ?? "import"
        let existing = currentSet(in: course.id, kind: check.kind, title: title)
        if let existing, decision == "import", let folder = existingFolder(of: existing) {
            return (409, [
                "conflict": true, "title": title, "courseId": course.id, "courseCode": course.code, "courseTitle": course.title,
                "weekLabel": folder.name, "folderId": folder.id, "folderName": folder.name,
                "existingQuestionCount": summary(of: existing)?.questions ?? 0, "incomingQuestionCount": check.questionCount, "setId": existing,
            ])
        }
        let replace = decision == "replace" ? existing : nil
        let folder: FakeStudy.Folder
        if let replace, let current = existingFolder(of: replace) {
            folder = current
        } else {
            switch study.importFolder(courseID: course.id, folderID: folderID, folderName: folderName) {
            case .success(let found): folder = found
            case .failure(let refusal): return refusal.reply
            }
        }
        let id = state.withLock { state -> String in
            state.importCount += 1
            let id = String(format: "5e700000-0000-4000-8000-%012d", 9000 + state.importCount)
            if let replace { state.imported[replace]?.isCurrent = false }
            state.imported[id] = ImportedEntry(
                courseID: course.id, title: title, kind: check.kind, questionCount: check.questionCount, termCount: check.termCount,
                importedAt: .now, status: replace == nil ? "imported" : "replaced", previous: replace
            )
            return id
        }
        if check.kind == "exam" {
            study.file(bank: FakeStudy.ids("bank-\(id)", check.questionCount), in: folder.id)
        } else {
            study.file(set: id, in: folder.id, replacing: replace, questionCount: check.questionCount)
        }
        let page = study.folders(course.id).first { $0.id == folder.id }?.examPageID
        return (201, [
            "kind": replace == nil ? "imported" : "replaced", "setKind": check.kind, "setId": id, "courseId": course.id,
            "courseCode": course.code, "title": title, "weekLabel": folder.name, "folderId": folder.id, "folderName": folder.name,
            "examPageId": json(page), "questionCount": check.questionCount, "termCount": check.termCount, "warnings": check.warnings,
        ])
    }

    /// A course an import makes, in the semester of that number, made too when it is missing.
    private func makeCourse(_ body: [String: Any]) -> Result<FakeCourse, FakeStudy.Failure> {
        state.withLock { state in
            guard let code = requiredText(body["code"] as? String ?? "", label: "Course code", maxLength: 32) else {
                return .failure(FakeStudy.Failure(status: 400, message: textProblem(body["code"] as? String ?? "", label: "Course code")))
            }
            guard let title = requiredText(body["title"] as? String ?? "", label: "Course name", maxLength: 160) else {
                return .failure(FakeStudy.Failure(status: 400, message: textProblem(body["title"] as? String ?? "", label: "Course name")))
            }
            guard let number = body["semesterNumber"] as? Int, (1...3).contains(number) else {
                return .failure(FakeStudy.Failure(status: 400, message: "A semester is 1, 2, or 3."))
            }
            if !state.semesters.contains(where: { $0.number == number }) {
                state.semesters.append(FakeSemester(id: "8d7b4f0e-0000-4000-8000-00000000000\(number)", number: number, name: "Semester \(number)"))
            }
            let semesterID = state.semesters.first { $0.number == number }!.id
            if let taken = codeTaken(code, in: semesterID, except: nil, courses: state.courses) {
                return .failure(FakeStudy.Failure(status: taken.0, message: taken.1["message"] as? String ?? ""))
            }
            state.tokenCount += 1
            let course = FakeCourse(
                id: String(format: "8d7b4f0e-0000-4000-8000-%012d", 900 + state.tokenCount), semesterID: semesterID, code: code, title: title,
                sortOrder: (state.courses.filter { $0.semesterID == semesterID }.map(\.sortOrder).max() ?? 0) + 1
            )
            state.courses.append(course)
            return .success(course)
        }
    }

    /// The course's current set of this kind and name, ignoring case.
    private func currentSet(in courseID: String, kind: String, title: String) -> String? {
        let practice = study.folders(courseID).flatMap(\.sets)
        let exams = state.withLock { state in
            state.imported.filter { $0.value.courseID == courseID && $0.value.kind == "exam" && $0.value.isCurrent }.map(\.key)
        }
        let candidates = kind == "exam" ? exams : practice
        return candidates.first { summary(of: $0)?.title.lowercased() == title.lowercased() }
    }

    /// The folder a current set, or an imported exam set, is in.
    private func existingFolder(of setID: String) -> FakeStudy.Folder? {
        if let folder = study.folder(holding: setID) { return folder }
        guard let courseID = state.withLock({ $0.imported[setID]?.courseID }) else { return nil }
        return study.folders(courseID).first { $0.bank.contains { $0.hasPrefix("bank-\(setID)-") } }
    }

    /// Brings back the version an imported set replaced.
    func restoreImported(_ id: String) -> Reply {
        let previous = state.withLock { state -> String? in
            guard let entry = state.imported[id], entry.isCurrent, let previous = entry.previous else { return nil }
            state.imported[id]?.isCurrent = false
            state.imported[previous]?.isCurrent = true
            return previous
        }
        guard let previous else { return failure(404, "request_refused", "That set is not the current version.") }
        study.replace(set: id, with: previous)
        return (200, set(previous))
    }
}
#endif
