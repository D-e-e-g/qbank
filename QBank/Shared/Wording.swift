import Foundation
import QBankKit

/// The lines the screens show, worded as the web app words them.
nonisolated enum Wording {
    /// "1 question", "86 questions".
    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    /// "today", or a short month and day such as "Oct 3" in the phone's language.
    static func when(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// A time today, such as "7:40 AM", or a short month and day such as "Oct 10", in the phone's language.
    static func time(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The badge on a course shown from the phone's copy: "Saved 7:40 AM", "Saved Oct 10".
    static func saved(_ date: Date, now: Date = .now) -> String {
        "Saved \(time(date, now: now))"
    }

    /// Answers on the phone that QBank does not have yet: "3 waiting to send".
    static func waitingToSend(_ count: Int) -> String {
        "\(count) waiting to send"
    }

    /// When a group of waiting answers was given: "answered 8:02 AM", "answered 8:02 to 8:06 AM".
    static func answered(from first: Date, to last: Date, now: Date = .now) -> String {
        let start = time(first, now: now)
        let end = time(last, now: now)
        return start == end ? "answered \(start)" : "answered \(start) to \(end)"
    }

    /// A saved course in Saved for offline: "86 questions · updated 7:40 AM", or
    /// "70 of 86 questions · updated 7:40 AM" while some of its sets are not saved yet.
    static func savedCourse(_ course: SavedCourse, now: Date = .now) -> String {
        let questions = course.isComplete
            ? count(course.questionCount, "question")
            : "\(min(course.savedQuestionCount, course.questionCount)) of \(count(course.questionCount, "question"))"
        return "\(questions) · updated \(time(course.savedAt, now: now))"
    }

    /// The Saved for offline row in Settings: "2 courses · updated 7:40 AM".
    static func savedCourses(_ courses: [SavedCourse], now: Date = .now) -> String {
        guard let latest = courses.map(\.savedAt).max() else { return "Nothing saved yet" }
        return "\(count(courses.count, "course")) · updated \(time(latest, now: now))"
    }

    // MARK: Courses and study topics

    /// Every word a study topic says differently from a course, from the kind the server sends, as
    /// the web's `kindWords` says them (`apps/web/src/course/pages.ts`). Both have pages; what a
    /// page is for is its badge. Everything inside works the same, the timed exam included, so
    /// nothing else differs. A kind this version does not know reads as a course.
    static func words(_ kind: CourseKind) -> KindWords {
        kind == .topic ? .topic : .course
    }

    /// What the screens call a course or topic: a course by its code ("NURS 420"), a topic by its
    /// name, since its code is empty.
    static func name(_ course: some CourseNaming) -> String {
        course.kind == .topic ? course.title : course.code
    }

    /// A course's code and name ("NURS 420 · Health assessment"), and a topic's name alone.
    static func line(_ course: some CourseNaming) -> String {
        course.kind == .topic ? course.title : "\(course.code) · \(course.title)"
    }

    /// The kind of a course or topic from a body that carries no kind, such as a question job's
    /// course: the server leaves only a topic's code empty, and refuses an empty one for a course.
    static func kind(code: String) -> CourseKind {
        code.isEmpty ? .topic : .course
    }

    /// What to call a course or topic from a body that carries no kind: its code, or a topic's name.
    static func name(code: String, title: String) -> String {
        kind(code: code) == .topic ? title : code
    }

    /// The next free page name in a course or topic: "Page 3" with two pages, skipping a name
    /// already used, in any case. Her pages keep the names they have, such as "Exam 1".
    static func nextPageName(after names: [String]) -> String {
        let taken = Set(names.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var number = names.count + 1
        while taken.contains("page \(number)") { number += 1 }
        return "Page \(number)"
    }

    /// A page's badge as its tag and its choice in the editor: "Exam", "Concept", "Study".
    static func badge(_ badge: PageBadge) -> String {
        switch badge {
        case .exam: "Exam"
        case .concept: "Concept"
        case .study: "Study"
        }
    }

    /// The course line on Home and under the Course title: "86 questions · 3 folders".
    static func size(questions: Int, folders: Int) -> String {
        "\(count(questions, "question")) · \(count(folders, "folder"))"
    }

    /// The line under a course's title: "Mental Health · 86 questions · 3 folders". A topic's name
    /// is its title already, so it says only "3 questions · 2 folders".
    static func summary(_ course: CourseDetail) -> String {
        let size = size(questions: course.questionCount, folders: course.folderCount)
        return course.kind == .topic ? size : "\(course.title) · \(size)"
    }

    /// "35 of 86 answered · 24 fully right · 61 of 92 points", or nil before her first answer.
    static func score(_ course: CourseDetail) -> String? {
        guard course.answeredCount > 0 else { return nil }
        return "\(course.answeredCount) of \(course.questionCount) answered · \(course.fullyRightCount) fully right · \(course.points) of \(course.maxPoints) points"
    }

    /// Share of the course's questions she has answered, 0 to 100, as the Home card shows it.
    static func answeredPercent(_ course: CourseSummary) -> Int {
        guard course.questionCount > 0 else { return 0 }
        let answered = min(course.answeredCount, course.questionCount)
        return Int((Double(answered) / Double(course.questionCount) * 100).rounded())
    }

    /// How long an exam over every folder takes, as the server's rules give it: "60 min", "7.5 min".
    /// "Not ready" without questions, and "Timed" from a copy saved before the app read the time.
    static func examTime(_ course: CourseDetail) -> String {
        guard course.examQuestionCount > 0 else { return "Not ready" }
        guard let seconds = course.examTimeLimitSeconds else { return "Timed" }
        let minutes = Double(seconds) / 60
        return minutes.rounded() == minutes ? "\(Int(minutes)) min" : String(format: "%.1f min", minutes)
    }

    /// A set's line on the Course screen: when it arrived, how far she got, or how it went. Continue
    /// shows only on a row that opens the set.
    static func status(_ set: PracticeSetSummary, opens: Bool = true, now: Date = .now) -> String {
        if opens, let answered = continuing(set) {
            return "\(answered) · \(continueWord)"
        }
        if set.answeredCount == 0 {
            let word = switch set.status {
            case .imported: "Imported"
            case .replaced: "Replaced"
            case .restored: "Restored"
            }
            return "\(word) \(when(set.activeSince, now: now)) · \(count(set.questionCount, "question"))"
        }
        if everyQuestionAnswered(set) {
            let finished = set.lastAnsweredAt ?? set.activeSince
            return "Done \(when(finished, now: now)) · \(set.fullyRightCount) of \(set.questionCount) fully right"
        }
        return "\(set.answeredCount) of \(set.questionCount) answered"
    }

    /// Every question of the set has an answer, which is when its row can say Done.
    static func everyQuestionAnswered(_ set: PracticeSetSummary) -> Bool {
        set.questionCount > 0 && set.answeredCount >= set.questionCount
    }

    /// Above question 1 when a finished set opens. Answering starts a new run, and nothing else says so.
    static let newRunNotice = "You've answered this set before. Answering now starts a new practice run."

    /// The word that says a set opens where she left it.
    static let continueWord = "Continue"

    /// How far a set she can continue has got: "7 of 12 answered". Nil when there is nothing to continue.
    static func continuing(_ set: PracticeSetSummary) -> String? {
        set.sitting.map { "\($0.answeredCount) of \(set.questionCount) answered" }
    }

    /// The line under a set's title when it opens where she left it: "Picked up at 8 · 7 answered
    /// earlier", or "Picked up at 8 · last answered Oct 20" for a set left on another day.
    static func pickedUp(at number: Int, answeredEarlier: Int, lastAnsweredAt: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        if let lastAnsweredAt, !calendar.isDate(lastAnsweredAt, inSameDayAs: now) {
            return "Picked up at \(number) · last answered \(when(lastAnsweredAt, now: now, calendar: calendar))"
        }
        return "Picked up at \(number) · \(answeredEarlier) answered earlier"
    }

    /// What Start over asks once: "Your 7 answers stay saved and still count. The set begins again
    /// at question 1."
    static func startOverMessage(answers: Int) -> String {
        let saved = answers == 1 ? "stays saved and still counts" : "stay saved and still count"
        return "Your \(count(answers, "answer")) \(saved). The set begins again at question 1."
    }

    /// The folders an exam covers, by name: "First Pass, Second Pass". Folders named plainly
    /// "Week N" read as she would say them, as before folders: "Weeks 1-3", "Weeks 1-2, 4", "Week 2".
    static func folders(_ names: [String]) -> String {
        let numbers = names.map { name in
            name.trimmingCharacters(in: .whitespaces).wholeMatch(of: /Week (\d+)/).flatMap { Int($0.output.1) }
        }
        guard !names.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return names.joined(separator: ", ") }
        let sorted = Array(Set(numbers.compactMap(\.self))).sorted()
        if sorted.count == 1 { return "Week \(sorted[0])" }
        var runs: [String] = []
        var start = sorted[0]
        var end = start
        for number in sorted.dropFirst() {
            if number == end + 1 {
                end = number
                continue
            }
            runs.append(start == end ? "\(start)" : "\(start)-\(end)")
            start = number
            end = number
        }
        runs.append(start == end ? "\(start)" : "\(start)-\(end)")
        return "Weeks \(runs.joined(separator: ", "))"
    }

    /// "33 minutes", or "10.5 minutes" for an odd number of questions at 1.5 minutes each.
    static func minutes(seconds: Int) -> String {
        let minutes = Double(seconds) / 60
        let shown = minutes.rounded() == minutes ? "\(Int(minutes))" : String(format: "%.1f", minutes)
        return "\(shown) \(minutes == 1 ? "minute" : "minutes")"
    }

    /// Which of an exam's folders use practice questions because they have no exam bank:
    /// "Week 3 has no exam bank yet, so it uses its practice questions." before the exam, and
    /// "Weeks 1-2 had no exam bank, so their questions came from practice sets." after it.
    static func practiceFolders(_ names: [String], before: Bool) -> String {
        let one = names.count == 1
        let folders = folders(names)
        if before {
            return "\(folders) \(one ? "has" : "have") no exam bank yet, so \(one ? "it uses its" : "they use their") practice questions."
        }
        return "\(folders) had no exam bank, so \(one ? "its" : "their") questions came from practice sets."
    }

    /// The format line above a question: "Single answer", "Select all that apply".
    static func format(_ type: QuestionType?) -> String {
        switch type {
        case .single: "Single answer"
        case .priority: "Priority / first action"
        case .sata: "Select all that apply"
        case .highlight: "Highlight"
        case .order: "Ordering"
        case .match: "Matching"
        case .matrix: "Matrix"
        case .cloze: "Drop-down"
        case nil: "Question"
        }
    }

    /// A set result's points and how long it took: "15 of 22 points · 24 min", or only the points for
    /// a set she picked up where she left it.
    static func resultPoints(_ result: PracticeResult) -> String {
        let points = "\(result.points) of \(result.maxPoints) points"
        return result.elapsed.map { "\(points) · \(duration($0))" } ?? points
    }

    /// How long a run took: "45 sec" under a minute, then whole minutes, "1 min", "24 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(whole) sec" }
        let minutes = max(1, Int((Double(whole) / 60).rounded()))
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    /// What went wrong, in words for her. The server's own messages are written for her, so they
    /// are shown as they come; everything else is said plainly. Nil when there is nothing to say.
    @MainActor
    static func problem(_ error: QBankError) -> String? {
        switch error {
        case .server(let server):
            return server.message
        case .transport(let code):
            switch code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "No connection. Check Wi-Fi or cellular data and try again."
            case .timedOut:
                return "QBank took too long to answer. Try again."
            default:
                return "QBank could not be reached. Try again in a moment."
            }
        case .unexpectedResponse(let status, _):
            return status >= 500
                ? "QBank is having trouble right now. Try again in a moment."
                : "Something went wrong. Try again."
        case .storage:
            return "This \(Device.model) could not keep your sign-in. Try again."
        case .notSignedIn:
            return "Sign in to continue."
        case .invalidRequest:
            return "Something went wrong. Try again."
        case .cancelled:
            return nil
        }
    }
}

/// The words a course and a study topic say differently; `Wording.words(_:)` picks them by kind.
nonisolated struct KindWords: Equatable {
    /// "course" or "topic", inside a sentence: "This topic has no question sets yet."
    let container: String

    /// An open page deleted elsewhere, such as on the web.
    var pageGone: String {
        "This page is not in the \(container) anymore. If it was deleted, Recently deleted in the \(container) can bring it back."
    }

    static let course = KindWords(container: "course")
    static let topic = KindWords(container: "topic")
}

/// A course or topic as the screens name it: its kind, code and name.
nonisolated protocol CourseNaming {
    var kind: CourseKind { get }
    var code: String { get }
    var title: String { get }
}

nonisolated extension CourseSummary: CourseNaming {}
nonisolated extension CourseDetail: CourseNaming {}
nonisolated extension DeletedCourse: CourseNaming {}
