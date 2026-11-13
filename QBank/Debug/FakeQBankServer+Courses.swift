#if DEBUG
import Foundation
import QBankKit

/// What the fake server answers about her courses: Home's semesters and topics with their counts,
/// a course's detail with its folders, and each set's line, counting the progress she had before
/// the scenario and the answers she gives here.
nonisolated extension FakeQBankServer {
    // MARK: Courses

    /// Her semesters with their courses, and her study topics in her order.
    func catalog() -> [String: Any] {
        state.withLock { state in
            [
                "semesters": state.semesters.sorted { $0.number < $1.number }.map { semesterJSON($0, in: state) },
                "topics": Self.topics(in: state).map { courseJSON($0, in: state) },
            ]
        }
    }

    /// Her topics in her order, without the ones she deleted.
    static func topics(in state: State) -> [FakeCourse] {
        state.courses.filter { $0.kind == "topic" && $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func semesterJSON(_ semester: FakeSemester, in state: State) -> [String: Any] {
        [
            "id": semester.id, "number": semester.number, "name": semester.name,
            "startsOn": json(semester.startsOn), "endsOn": json(semester.endsOn), "archivedAt": json(semester.archivedAt),
            "courses": state.courses.filter { $0.kind == "course" && $0.semesterID == semester.id && $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }.map { courseJSON($0, in: state) },
        ]
    }

    func courseJSON(_ course: FakeCourse, in state: State) -> [String: Any] {
        let added = Self.added(courseID: course.id, latest: state.latest)
        // The two studied courses count the folders she has now; the others, their invented count.
        let folders = study.knows(course.id) ? study.folders(course.id) : nil
        return [
            "id": course.id, "kind": course.kind, "code": course.code, "title": course.title, "sortOrder": course.sortOrder,
            "archivedAt": json(course.archivedAt),
            "questionCount": course.questions + importedQuestions(course.id, in: state),
            "weekCount": folders.map { Set($0.filter { !$0.sets.isEmpty }.map(\.name)).count } ?? course.folders,
            "folderCount": folders?.count ?? course.folders,
            "reviewCount": FakeStudy.codes[course.id] == nil ? course.review : study.reviewCount(course.id),
            "answeredCount": course.answered + added.answered, "fullyRightCount": course.right + added.right,
            "points": course.points, "maxPoints": course.maxPoints,
        ]
    }

    /// Progress she made before the scenario starts, by set: questions answered, fully right, and
    /// days since her last answer.
    static let earlierProgress: [String: (answered: Int, right: Int, lastAnsweredDaysAgo: Int)] = [
        "rights-v1": (17, 13, 9),
        "communication-v1": (9, 6, 1),
        "vitals-v1": (43, 35, 1),
        "safety-v1": (42, 30, 1),
        "mobility-v1": (7, 5, 1),
    ]

    /// Every set of each course, in all its versions.
    private static let setsByCourse: [String: Set<String>] = [
        mentalHealthID: ["rights-v1", "communication-v1", "psychosocial-v1", "psychosocial-v2", "depression-v1", "anxiety-v1", "mixed-v1"],
        fundamentalsID: ["vitals-v1", "safety-v1", "mobility-v1"],
    ]

    /// What her answers here add to a course's invented counts. A set she answered here counts her
    /// answers instead of its earlier progress, as the set's own line does.
    private static func added(courseID: String, latest: [String: (status: String, at: Date)]) -> (answered: Int, right: Int) {
        let sets = setsByCourse[courseID] ?? []
        var bySet: [String: [String]] = [:]
        for (questionID, answer) in latest {
            let setID = questionID.split(separator: "-").dropLast().joined(separator: "-")
            if sets.contains(setID) {
                bySet[setID, default: []].append(answer.status)
            }
        }
        return bySet.reduce(into: (0, 0)) { total, entry in
            let earlier = earlierProgress[entry.key]
            let overlapping = (0..<(earlier?.answered ?? 0)).compactMap { latest["\(entry.key)-q\($0)"]?.status }
            let counts = counts(setID: entry.key, answered: entry.value, overlappingEarlier: overlapping)
            total.0 += counts.answered - (earlier?.answered ?? 0)
            total.1 += counts.right - (earlier?.right ?? 0)
        }
    }

    /// A set's answered and fully right questions: her invented earlier answers, which a new answer
    /// to the same question replaces, and her answers here. Whether a replaced earlier answer was
    /// right is not kept, so it counts as her first ones are invented, right before wrong.
    private static func counts(setID: String, answered: [String], overlappingEarlier: [String]) -> (answered: Int, right: Int) {
        let earlier = earlierProgress[setID]
        let answeredCount = (earlier?.answered ?? 0) + answered.count - overlappingEarlier.count
        let rightHere = answered.count { $0 == "correct" }
        let rightEarlier = max(0, (earlier?.right ?? 0) - overlappingEarlier.count)
        return (answeredCount, rightHere + rightEarlier)
    }

    /// What Home and the delete call it: a course by its code, a topic by its name.
    static func name(_ course: FakeCourse) -> String {
        course.kind == "topic" ? course.title : course.code
    }

    /// The fields a course's detail shares with Settings, which can rename and move it.
    func stored(_ id: String) -> [String: Any] {
        state.withLock { state in
            let course = state.courses.first { $0.id == id }!
            let semester = state.semesters.first { $0.id == course.semesterID }
            return [
                "id": course.id, "kind": course.kind, "code": course.code, "title": course.title, "archivedAt": json(course.archivedAt),
                "semester": semester.map { ["id": $0.id, "number": $0.number, "name": $0.name] as Any } ?? NSNull(),
            ]
        }
    }

    /// What a course's detail says about her study: its exams, and her Review and terms counts.
    func studied(_ id: String) -> [String: Any] {
        ["exams": study.courseExamsJSON(id), "reviewCount": study.reviewCount(id), "termCount": study.termCount(id)]
    }

    func mentalHealth() -> [String: Any] {
        let (added, imported) = state.withLock { (Self.added(courseID: Self.mentalHealthID, latest: $0.latest), importedQuestions(Self.mentalHealthID, in: $0)) }
        return [
            "id": Self.mentalHealthID, "code": "NURS 310", "title": "Mental Health", "archivedAt": NSNull(),
            "semester": ["id": "fake-semester-1", "number": 1, "name": "Semester 1"],
            "questionCount": 86 + imported, "examQuestionCount": 134 + imported,
            "examTimeLimitSeconds": FakeStudy.examTime(questionCount: 134 + imported), "termCount": 180, "reviewCount": 12,
            "answeredCount": 35 + added.answered, "fullyRightCount": 24 + added.right, "points": 61, "maxPoints": 92,
        ].merging(folders(Self.mentalHealthID)) { _, folders in folders }
    }

    func fundamentals() -> [String: Any] {
        let (added, imported) = state.withLock { (Self.added(courseID: Self.fundamentalsID, latest: $0.latest), importedQuestions(Self.fundamentalsID, in: $0)) }
        return [
            "id": Self.fundamentalsID, "code": "NURS 220", "title": "Fundamentals", "archivedAt": NSNull(),
            "semester": ["id": "fake-semester-1", "number": 1, "name": "Semester 1"],
            "questionCount": 146 + imported, "examQuestionCount": 146 + imported,
            "examTimeLimitSeconds": FakeStudy.examTime(questionCount: 146 + imported), "termCount": 212, "reviewCount": 5,
            "answeredCount": 92 + added.answered, "fullyRightCount": 70 + added.right, "points": 131, "maxPoints": 170,
        ].merging(folders(Self.fundamentalsID)) { _, folders in folders }
    }

    /// A course's folders with their sets, and the same sets by folder name for an app from before
    /// folders, as the server sends both.
    private func folders(_ courseID: String) -> [String: Any] {
        let folders = study.folders(courseID)
        var weeks: [[String: Any]] = []
        for folder in folders.sorted(by: { Self.weekOrder($0.name, $1.name) }) {
            let sets = folder.sets.map(set)
            if let index = weeks.firstIndex(where: { $0["label"] as? String == folder.name }) {
                weeks[index]["sets"] = (weeks[index]["sets"] as? [[String: Any]] ?? []) + sets
                weeks[index]["examBankCount"] = (weeks[index]["examBankCount"] as? Int ?? 0) + folder.bank.count
            } else {
                weeks.append(["label": folder.name, "sets": sets, "examBankCount": folder.bank.count])
            }
        }
        return [
            "folders": folders.map(folderJSON),
            "folderCount": folders.count,
            "weeks": weeks,
            "weekCount": weeks.count { !(($0["sets"] as? [[String: Any]]) ?? []).isEmpty },
        ]
    }

    /// A folder as the server sends it, with its sets and its exam bank's sets.
    func folderJSON(_ folder: FakeStudy.Folder) -> [String: Any] {
        [
            "id": folder.id, "name": folder.name, "examPageId": json(folder.examPageID), "sortOrder": folder.sortOrder,
            "sets": folder.sets.map(set), "examBankCount": folder.bank.count,
            "examSets": FakeStudy.examSets(folder)
                .map { ["id": $0.id, "title": examSetTitle($0.id), "questionCount": $0.questionIDs.count] }
                .sorted { ($0["title"] as? String ?? "").localizedCompare($1["title"] as? String ?? "") == .orderedAscending },
        ]
    }

    /// The server's week order (`compareWeeks`): by the first number in the name, then by name.
    private static func weekOrder(_ a: String, _ b: String) -> Bool {
        let rank = { (name: String) in name.firstMatch(of: /\d+/).flatMap { Int($0.output) } ?? Int.max }
        let (left, right) = (rank(a), rank(b))
        return left == right ? a.localizedCompare(b) == .orderedAscending : left < right
    }

    /// Every set of the invented courses: title, size, how many days ago it arrived, and how.
    static let catalog: [String: (title: String, questions: Int, daysAgo: Int, status: String, canRestore: Bool)] = [
        "rights-v1": ("Rights, Law, and Ethics", 17, 20, "imported", false),
        "communication-v1": ("Therapeutic Communication and the Relationship", 14, 12, "imported", false),
        "psychosocial-v2": ("Psychosocial Assessment and Safety Screening", 12, 6, "replaced", true),
        "psychosocial-v1": ("Psychosocial Assessment and Safety Screening", 12, 0, "restored", true),
        "depression-v1": ("Depression and Antidepressants", 18, 0, "imported", false),
        "anxiety-v1": ("Anxiety, Panic, and Anxiolytics", 13, 0, "imported", false),
        "mixed-v1": ("Mixed Clinical Judgment", 8, 4, "imported", false),
        FakePracticeQuestions.findingsSetID: ("Findings and Disorders", 1, 1, "imported", false),
        FakePracticeQuestions.allCorrectSetID: ("Safe Blood Draw", 1, 1, "imported", false),
        "vitals-v1": ("Vital Signs Under Pressure", 43, 30, "imported", false),
        "safety-v1": ("Safety and Infection Control", 42, 22, "imported", false),
        "mobility-v1": ("Mobility and Skin Integrity", 61, 8, "imported", false),
    ]

    /// A set's title, size, when it arrived and how, from the invented catalog or an import.
    func summary(of id: String) -> (title: String, questions: Int, importedAt: Date, status: String, canRestore: Bool)? {
        if let entry = Self.catalog[id] {
            return (entry.title, entry.questions, now.addingTimeInterval(TimeInterval(-entry.daysAgo) * 86_400), entry.status, entry.canRestore)
        }
        return state.withLock { state in
            state.imported[id].map { ($0.title, $0.questionCount, $0.importedAt, $0.status, $0.previous != nil) }
        }
    }

    func set(_ id: String) -> [String: Any] {
        let entry = summary(of: id) ?? ("Invented set", 0, now, "imported", false)
        let earlier = Self.earlierProgress[id]
        let questionIDs = (0..<entry.questions).map { "\(id)-q\($0)" }
        // Once she answers here, the set's line counts her answers, as the server's does.
        let (latest, overlapping, sitting, run) = state.withLock { state in
            (
                questionIDs.compactMap { state.latest[$0] },
                questionIDs.prefix(earlier?.answered ?? 0).compactMap { state.latest[$0]?.status },
                Self.continuing(setID: id, questionIDs: questionIDs, state: state),
                Self.run(setID: id, questionIDs: questionIDs, state: state)
            )
        }
        var json: [String: Any] = [
            "id": id, "title": entry.title, "description": "", "questionCount": entry.questions,
            "importedAt": QBankJSON.formatDate(entry.importedAt), "activeSince": QBankJSON.formatDate(entry.importedAt),
            "status": entry.status, "canRestore": entry.canRestore, "questionIds": questionIDs,
            "importedByAgent": FakeAgents.importer(ofSet: id) ?? NSNull(),
            "sitting": sitting.map { ["answeredCount": $0.count] as Any } ?? NSNull(),
            "run": run,
        ]
        if latest.isEmpty {
            json["answeredCount"] = earlier?.answered ?? 0
            json["fullyRightCount"] = earlier?.right ?? 0
            json["lastAnsweredAt"] = self.json(earlier.map { date(days: -$0.lastAnsweredDaysAgo) })
        } else {
            let counts = Self.counts(setID: id, answered: latest.map(\.status), overlappingEarlier: overlapping)
            json["answeredCount"] = counts.answered
            json["fullyRightCount"] = counts.right
            json["lastAnsweredAt"] = QBankJSON.formatDate(latest.map(\.at).max() ?? now)
        }
        return json
    }

    /// A course that is not one of the two studied ones, such as one Settings or an import added.
    func plainCourse(_ id: String) -> Reply {
        let imported = state.withLock { state -> Int? in
            state.courses.contains { $0.id == id } ? importedQuestions(id, in: state) : nil
        }
        guard let imported else { return failure(404, "request_refused", "That course is not in the app.") }
        let counts: [String: Any] = [
            "questionCount": imported, "examQuestionCount": imported, "examTimeLimitSeconds": FakeStudy.examTime(questionCount: imported),
            "answeredCount": 0, "fullyRightCount": 0, "points": 0, "maxPoints": 0,
        ]
        return (200, counts.merging(folders(id)) { _, folders in folders }.merging(stored(id)) { _, stored in stored }.merging(studied(id)) { _, now in now })
    }

    /// The questions of a course's current imported practice sets.
    private func importedQuestions(_ courseID: String, in state: State) -> Int {
        state.imported.values.filter { $0.courseID == courseID && $0.isCurrent && $0.kind == "practice" }.reduce(0) { $0 + $1.questionCount }
    }
}
#endif
