import Foundation
import Observation
import QBankDesign
import QBankKit

/// The course's Review list: what she missed, got partly right, or guessed, filtered as the web's
/// Review screen filters it (`apps/web/src/screens/ReviewScreen.tsx`). A question leaves when she
/// answers it fully right without guessing, or when she clears the list. The whole list is read
/// once and filtered on the phone with the server's rule, so the filters work without a connection
/// on the copy saved last.
@Observable
final class ReviewModel {
    let course: CourseRef
    private(set) var filter: ReviewFilter = .all
    /// The whole list, every filter's counts with it.
    private(set) var list: ReviewList?
    /// When the list on screen was saved on the phone, or nil when it came from QBank just now.
    private(set) var savedAt: Date?
    private(set) var problem: String?
    private(set) var isClearing = false

    private let app: AppModel

    init(app: AppModel, course: CourseRef) {
        self.app = app
        self.course = course
    }

    /// The questions under the chosen filter.
    var questions: [ReviewQuestion] {
        (list?.questions ?? []).filter { Self.matches($0, filter) }
    }

    /// How many questions the chosen filter holds, for "Practice these N".
    var selectedCount: Int {
        list.map { Self.count(of: filter, in: $0.counts) } ?? 0
    }

    var allCount: Int {
        list?.counts.all ?? 0
    }

    /// Loads the whole list, or without a connection the copy saved last. A failed reload keeps
    /// what is on screen.
    func load() async {
        let id = course.id
        do {
            let loaded = try await app.load(.review(courseID: id)) { () async throws(QBankError) in try await app.client.review(courseID: id) }
            list = loaded.value
            savedAt = loaded.savedAt
            problem = nil
        } catch {
            report(error)
        }
    }

    func choose(_ filter: ReviewFilter) {
        self.filter = filter
    }

    /// The server's filter rule (`matchesFilter`): missed and partly right by her last mark, guessed
    /// by her last guess.
    nonisolated static func matches(_ question: ReviewQuestion, _ filter: ReviewFilter) -> Bool {
        switch filter {
        case .all: true
        case .missed: question.status == .incorrect
        case .partial: question.status == .partial
        case .guessed: question.guessed
        }
    }

    /// Empties the list after she confirmed. Her answers and scores stay.
    func clear() async {
        guard !app.frozen.refuses() else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await app.client.clearReview(courseID: course.id)
            problem = nil
        } catch {
            report(error)
            return
        }
        await load()
    }

    /// The runner over the filtered list, shuffled by the server, or over one question of it.
    func practice(_ question: ReviewQuestion? = nil) -> PracticeRoute {
        PracticeRoute(source: .review(filter: filter, questionID: question?.questionID), courseID: course.id, title: "Review", kind: course.kind)
    }

    /// The confirmation she answers before the list is emptied, in the web's words.
    var clearTitle: String {
        "Clear all \(Wording.count(allCount, "question")) from this \(Wording.words(course.kind).container)'s Review list?"
    }

    static func count(of filter: ReviewFilter, in counts: ReviewList.Counts) -> Int {
        switch filter {
        case .all: counts.all
        case .missed: counts.missed
        case .partial: counts.partial
        case .guessed: counts.guessed
        }
    }

    private func report(_ error: QBankError) {
        guard !app.handle(error), let words = Wording.problem(error) else { return }
        problem = words
    }
}

extension ReviewQuestion {
    /// The mark a Review row carries, as the web marks it: partly right, a right guess, or missed,
    /// each saying when it was a guess.
    nonisolated var mark: (status: QBankAnswerStatus, label: String) {
        switch status {
        case .partial: (.partial, guessed ? "Partly right, guessed" : "Partly right")
        case .correct: (.guessed, "Guessed")
        case .incorrect: (.wrong, guessed ? "Missed, guessed" : "Missed")
        }
    }
}
