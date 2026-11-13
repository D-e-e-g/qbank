#if DEBUG
import Foundation
import QBankKit

/// Adding and editing semesters, courses and study topics on the fake server, with the content
/// service's rules and words.
nonisolated extension FakeQBankServer {
    // MARK: Editing semesters and courses, with the content service's rules and words

    func addSemester(number: Int?) -> Reply {
        guard let number, (1...3).contains(number) else {
            return failure(400, "request_refused", "A semester is 1, 2, or 3.")
        }
        return state.withLock { state -> Reply in
            guard !state.semesters.contains(where: { $0.number == number }) else {
                return failure(409, "request_refused", "Semester \(number) already exists.")
            }
            let semester = FakeSemester(id: "8d7b4f0e-0000-4000-8000-00000000000\(number)", number: number, name: "Semester \(number)")
            state.semesters.append(semester)
            return (201, semesterJSON(semester, in: state))
        }
    }

    func updateSemester(id: String, body: [String: Any]) -> Reply {
        state.withLock { state -> Reply in
            guard let index = state.semesters.firstIndex(where: { $0.id == id }) else {
                return failure(404, "request_refused", "That semester is not in the app.")
            }
            var semester = state.semesters[index]
            if let name = body["name"] as? String {
                guard let text = requiredText(name, label: "Semester name", maxLength: 80) else {
                    return failure(400, "request_refused", textProblem(name, label: "Semester name"))
                }
                semester.name = text
            }
            for (key, label) in [("startsOn", "Start date"), ("endsOn", "End date")] where body.keys.contains(key) {
                let value = body[key] as? String
                if let value, !value.isEmpty, value.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) == nil {
                    return failure(400, "request_refused", "\(label) has to be a date like 2026-09-01.")
                }
                let date = value?.isEmpty == false ? value : nil
                if key == "startsOn" { semester.startsOn = date } else { semester.endsOn = date }
            }
            if let archived = body["archived"] as? Bool {
                semester.archivedAt = archived ? QBankJSON.formatDate(.now) : nil
            }
            state.semesters[index] = semester
            return (200, semesterJSON(semester, in: state))
        }
    }

    func addCourse(semesterID: String, code: String, title: String) -> Reply {
        state.withLock { state -> Reply in
            guard state.semesters.contains(where: { $0.id == semesterID }) else {
                return failure(404, "request_refused", "That semester is not in the app.")
            }
            guard let code = requiredText(code, label: "Course code", maxLength: 32) else {
                return failure(400, "request_refused", textProblem(code, label: "Course code"))
            }
            guard let title = requiredText(title, label: "Course name", maxLength: 160) else {
                return failure(400, "request_refused", textProblem(title, label: "Course name"))
            }
            if let taken = codeTaken(code, in: semesterID, except: nil, courses: state.courses) { return taken }
            state.tokenCount += 1
            let order = (state.courses.filter { $0.semesterID == semesterID }.map(\.sortOrder).max() ?? 0) + 1
            let course = FakeCourse(
                id: String(format: "8d7b4f0e-0000-4000-8000-%012d", 900 + state.tokenCount),
                semesterID: semesterID, code: code, title: title, sortOrder: order
            )
            state.courses.append(course)
            return (201, courseJSON(course, in: state))
        }
    }

    func updateCourse(id: String, body: [String: Any]) -> Reply {
        state.withLock { state -> Reply in
            guard let index = state.courses.firstIndex(where: { $0.id == id }) else {
                return failure(404, "request_refused", "That course is not in the app.")
            }
            var course = state.courses[index]
            if course.kind == "topic" {
                switch updateTopic(course, body: body, in: state) {
                case .success(let edited):
                    state.courses[index] = edited
                    return (200, courseJSON(edited, in: state))
                case .failure(let refusal):
                    return refusal.reply
                }
            }
            if let code = body["code"] as? String {
                guard let text = requiredText(code, label: "Course code", maxLength: 32) else {
                    return failure(400, "request_refused", textProblem(code, label: "Course code"))
                }
                course.code = text
            }
            if let title = body["title"] as? String {
                guard let text = requiredText(title, label: "Course name", maxLength: 160) else {
                    return failure(400, "request_refused", textProblem(title, label: "Course name"))
                }
                course.title = text
            }
            if let semesterID = body["semesterId"] as? String, semesterID != course.semesterID {
                guard state.semesters.contains(where: { $0.id == semesterID }) else {
                    return failure(404, "request_refused", "That semester is not in the app.")
                }
                course.semesterID = semesterID
                course.sortOrder = (state.courses.filter { $0.semesterID == semesterID }.map(\.sortOrder).max() ?? 0) + 1
            }
            if let taken = codeTaken(course.code, in: course.semesterID, except: id, courses: state.courses) { return taken }
            if let archived = body["archived"] as? Bool {
                course.archivedAt = archived ? QBankJSON.formatDate(.now) : nil
            }
            state.courses[index] = course
            return (200, courseJSON(course, in: state))
        }
    }

    // MARK: Study topics, with the content service's rules

    func addTopic(title: String) -> Reply {
        state.withLock { state -> Reply in
            guard let text = requiredText(title, label: "Topic name", maxLength: 160) else {
                return failure(400, "request_refused", textProblem(title, label: "Topic name"))
            }
            if let taken = topicTaken(text, except: nil, in: state) { return taken.reply }
            state.tokenCount += 1
            let topic = FakeCourse(
                id: String(format: "7a0e0000-0000-4000-8000-%012d", 900 + state.tokenCount), kind: "topic",
                semesterID: "", code: "", title: text, sortOrder: (Self.topics(in: state).map(\.sortOrder).max() ?? 0) + 1
            )
            state.courses.append(topic)
            study.register(course: topic.id)
            return (201, courseJSON(topic, in: state))
        }
    }

    /// Refuses a list that does not name exactly her topics, archived ones too, once each.
    func setTopicOrder(_ ids: [String]?) -> Reply {
        state.withLock { state -> Reply in
            let topics = Self.topics(in: state)
            guard let ids, ids.count == topics.count, Set(ids) == Set(topics.map(\.id)) else {
                return failure(409, "request_refused", "Your topics changed. Reload and try again.")
            }
            for (position, id) in ids.enumerated() {
                guard let index = state.courses.firstIndex(where: { $0.id == id }) else { continue }
                state.courses[index].sortOrder = position + 1
            }
            return (200, ["topics": Self.topics(in: state).map { courseJSON($0, in: state) }])
        }
    }

    /// A topic takes its name and archiving only.
    private func updateTopic(_ topic: FakeCourse, body: [String: Any], in state: State) -> Result<FakeCourse, FakeStudy.Failure> {
        if body["code"] != nil || body["semesterId"] != nil {
            return .failure(FakeStudy.Failure(status: 400, message: "A topic has no code or semester."))
        }
        var edited = topic
        if let title = body["title"] as? String {
            guard let text = requiredText(title, label: "Topic name", maxLength: 160) else {
                return .failure(FakeStudy.Failure(status: 400, message: textProblem(title, label: "Topic name")))
            }
            if let taken = topicTaken(text, except: topic.id, in: state) { return .failure(taken) }
            edited.title = text
        }
        if let archived = body["archived"] as? Bool {
            edited.archivedAt = archived ? QBankJSON.formatDate(.now) : nil
        }
        return .success(edited)
    }

    private func topicTaken(_ title: String, except id: String?, in state: State) -> FakeStudy.Failure? {
        let taken = Self.topics(in: state).contains { $0.id != id && $0.title.lowercased() == title.lowercased() }
        return taken ? FakeStudy.Failure(status: 409, message: "You already have a topic named \(title).") : nil
    }

    func requiredText(_ value: String, label: String, maxLength: Int) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > maxLength ? nil : text
    }

    func textProblem(_ value: String, label: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(label) is required." : "\(label) is too long."
    }

    func codeTaken(_ code: String, in semesterID: String, except id: String?, courses: [FakeCourse]) -> Reply? {
        let taken = courses.contains { $0.semesterID == semesterID && $0.id != id && $0.deletedAt == nil && $0.code.lowercased() == code.lowercased() }
        return taken ? failure(409, "request_refused", "This semester already has a course with the code \(code).") : nil
    }
}
#endif
