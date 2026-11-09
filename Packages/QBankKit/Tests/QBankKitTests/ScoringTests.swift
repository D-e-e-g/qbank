import Foundation
import Testing
@testable import QBankKit

/// The server's scoring cases (`packages/questions/src/score.test.ts`), run against the Swift port.
@Suite("Scoring")
struct ScoringTests {
    static func options(_ correct: Set<Int>, count: Int) -> [QuestionOption] {
        (0..<count).map { QuestionOption(text: "Option \($0)", isCorrect: correct.contains($0)) }
    }

    func expectScore(_ body: QuestionBody, _ response: AnswerResponse?, _ points: Int, _ status: ScoreStatus, answered: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let score = try Scoring.score(body, response: response)
        #expect(score.points == points, sourceLocation: sourceLocation)
        #expect(score.status == status, sourceLocation: sourceLocation)
        #expect(score.answered == answered, sourceLocation: sourceLocation)
        #expect((0...score.maxPoints).contains(score.points), sourceLocation: sourceLocation)
    }

    @Test func single() throws {
        let body = QuestionBody.single(options: Self.options([0], count: 4))
        try expectScore(body, .single(choice: 0), 1, .correct)
        try expectScore(body, .single(choice: 1), 0, .incorrect)
        try expectScore(body, .single(choice: 9), 0, .incorrect)
        try expectScore(body, .single(choice: -1), 0, .incorrect)
        #expect(try Scoring.score(body, response: .single(choice: 0)).maxPoints == 1)
    }

    @Test func priority() throws {
        let body = QuestionBody.priority(options: Self.options([2], count: 4))
        try expectScore(body, .priority(choice: 2), 1, .correct)
        try expectScore(body, .priority(choice: 0), 0, .incorrect)
    }

    @Test func selectAll() throws {
        let body = QuestionBody.sata(options: Self.options([0, 2], count: 4))
        #expect(try Scoring.score(body, response: nil).maxPoints == 2)
        try expectScore(body, .sata(picks: [0, 2]), 2, .correct)
        try expectScore(body, .sata(picks: [0]), 1, .partial)
        try expectScore(body, .sata(picks: [0, 1, 2]), 1, .partial)
        try expectScore(body, .sata(picks: [0, 1, 3]), 0, .incorrect)
        try expectScore(body, .sata(picks: [1, 3]), 0, .incorrect)
        try expectScore(body, .sata(picks: [0, 0, 2]), 2, .correct)
        try expectScore(body, .sata(picks: [0, 2, 1, 1]), 1, .partial)
        try expectScore(body, .sata(picks: [0, 2, 9]), 1, .partial)
        try expectScore(body, .sata(picks: []), 0, .incorrect)
    }

    @Test func highlight() throws {
        let body = QuestionBody.highlight(segments: Self.options([1, 2], count: 4))
        try expectScore(body, .highlight(picks: [1, 2]), 2, .correct)
        try expectScore(body, .highlight(picks: [1, 3]), 0, .incorrect)
        try expectScore(body, .highlight(picks: [1]), 1, .partial)
    }

    @Test func order() throws {
        let body = QuestionBody.order(items: ["A", "B", "C", "D"].map { OrderItem(text: $0) })
        try expectScore(body, .order(positions: [0, 1, 2, 3]), 4, .correct)
        try expectScore(body, .order(positions: [0, 2, 1, 3]), 2, .partial)
        try expectScore(body, .order(positions: [1, 0, 3, 2]), 0, .incorrect)
        try expectScore(body, .order(positions: [0, 1, 2, 3, 4]), 4, .correct)
        try expectScore(body, .order(positions: [0, 1]), 2, .partial)
    }

    @Test func match() throws {
        let body = QuestionBody.match(
            pairs: [
                MatchPair(left: "Bradypnea", right: "Slow breathing"),
                MatchPair(left: "Hemoptysis", right: "Coughing up blood"),
                MatchPair(left: "Dyspnea", right: "Shortness of breath"),
            ],
            extra: [MatchExtra(right: "Fast breathing")]
        )
        try expectScore(body, .match(choices: ["Slow breathing", "Coughing up blood", "Shortness of breath"]), 3, .correct)
        try expectScore(body, .match(choices: ["Fast breathing", "Coughing up blood", "Shortness of breath"]), 2, .partial)
        try expectScore(body, .match(choices: ["Coughing up blood", "Shortness of breath", "Slow breathing"]), 0, .incorrect)
        try expectScore(body, .match(choices: ["Slow breathing", nil, nil]), 1, .partial)
    }

    @Test func matrix() throws {
        let body = QuestionBody.matrix(
            columns: ["Indicated", "Nonessential", "Contraindicated"],
            rows: [
                MatrixRow(text: "A", answer: "Indicated"),
                MatrixRow(text: "B", answer: "Nonessential"),
                MatrixRow(text: "C", answer: "Contraindicated"),
            ]
        )
        try expectScore(body, .matrix(choices: ["Indicated", "Nonessential", "Contraindicated"]), 3, .correct)
        try expectScore(body, .matrix(choices: ["Indicated", "Nonessential", "Nonessential"]), 2, .partial)
        try expectScore(body, .matrix(choices: ["Nonessential", "Indicated", "Contraindicated"]), 1, .partial)
        try expectScore(body, .matrix(choices: ["Nonessential", "Indicated", "Indicated"]), 0, .incorrect)
    }

    @Test func matrixMulti() throws {
        let body = QuestionBody.matrixmulti(
            columns: ["Column A", "Column B", "Column C"],
            rows: [
                MatrixMultiRow(text: "Finding one", answers: ["Column A"]),
                MatrixMultiRow(text: "Finding two", answers: ["Column A", "Column B", "Column C"]),
                MatrixMultiRow(text: "Finding three", answers: ["Column B", "Column C"]),
            ]
        )
        let all = AnswerResponse.matrixmulti(choices: [
            ["Column A"], ["Column A", "Column B", "Column C"], ["Column B", "Column C"],
        ])
        let score = try Scoring.score(body, response: all)
        #expect(score.maxPoints == 6)
        #expect(score.pointsText(for: .matrixmulti) == "6 of 6 points")
        try expectScore(body, all, 6, .correct)
        #expect(try Scoring.score(body, response: nil).maxPoints == 6)
        try expectScore(body, .matrixmulti(choices: [["Column A"], ["Column A"], ["Column B"]]), 3, .partial)
        try expectScore(body, .matrixmulti(choices: [["Column A"], ["Column A"], ["Column A", "Column B"]]), 2, .partial)
        try expectScore(body, .matrixmulti(choices: [["Column B", "Column C"], ["Column A"], []]), 0, .incorrect)
        let blank = try Scoring.score(body, response: .matrixmulti(choices: [[], ["Column A", "Column B", "Column C"], ["Column B", "Column C"]]))
        #expect(blank.points == 5)
        #expect(blank.status == .partial)
        #expect(blank.pointsText(for: .matrixmulti) == "5 of 6 points")
        try expectScore(
            body,
            .matrixmulti(choices: [["Column A", "Column A"], ["Column C", "Column B", "Column A"], ["Column C", "Column B"]]),
            6,
            .correct
        )
        try expectScore(
            body,
            .matrixmulti(choices: [["Column A", "Nope"], ["Column A", "Column B", "Column C"], ["Column B", "Column C"]]),
            5,
            .partial
        )
        let findings = QuestionBody.matrixmulti(
            columns: ["Hypovolemia", "Hypervolemia", "Both volume problems written out so the header wraps"],
            rows: [
                MatrixMultiRow(text: "Dry mouth", answers: ["Hypovolemia"]),
                MatrixMultiRow(text: "Crackles", answers: ["Hypervolemia"]),
                MatrixMultiRow(text: "Weight", answers: ["Hypovolemia", "Hypervolemia"]),
            ]
        )
        let mixed = try Scoring.score(findings, response: .matrixmulti(choices: [
            ["Hypovolemia", "Both volume problems written out so the header wraps"],
            ["Hypervolemia"],
            ["Hypovolemia"],
        ]))
        #expect(mixed == Score(points: 2, maxPoints: 4, status: .partial, answered: true))
        #expect(mixed.pointsText(for: .matrixmulti) == "2 of 4 points")
    }

    @Test func cloze() throws {
        let body = QuestionBody.cloze(Cloze(text: "{0} and {1}", blanks: [
            ClozeBlank(options: ["a", "b"], answer: 0),
            ClozeBlank(options: ["c", "d", "e"], answer: 2),
        ]))
        try expectScore(body, .cloze(choices: [0, 2]), 2, .correct)
        try expectScore(body, .cloze(choices: [0, 0]), 1, .partial)
        try expectScore(body, .cloze(choices: [1, 1]), 0, .incorrect)
        try expectScore(body, .cloze(choices: [0, nil]), 1, .partial)
    }

    @Test func unansweredEarnsNothingAndIsNotAnswered() throws {
        let body = QuestionBody.order(items: ["A", "B", "C"].map { OrderItem(text: $0) })
        try expectScore(body, nil, 0, .incorrect, answered: false)
        #expect(try Scoring.score(body, response: nil).maxPoints == 3)
    }

    @Test func reviewRules() throws {
        let body = QuestionBody.sata(options: Self.options([0, 2], count: 4))
        let right = try Scoring.score(body, response: .sata(picks: [0, 2]))
        let wrong = try Scoring.score(body, response: .sata(picks: [1]))
        let partial = try Scoring.score(body, response: .sata(picks: [0]))
        let skipped = try Scoring.score(body, response: nil)
        #expect(right.staysInReview(guessed: true))
        #expect(!right.staysInReview(guessed: false))
        #expect(wrong.staysInReview(guessed: false))
        #expect(partial.staysInReview(guessed: false))
        #expect(!skipped.staysInReview(guessed: false))
        #expect(!skipped.staysInReview(guessed: true))
    }

    @Test func answerInAnotherFormatThrows() {
        #expect(throws: ScoringError.self) {
            try Scoring.score(.single(options: Self.options([0], count: 3)), response: .sata(picks: [0]))
        }
        let matrix = QuestionBody.matrix(columns: ["A"], rows: [MatrixRow(text: "Row", answer: "A")])
        #expect(throws: ScoringError.self) {
            try Scoring.score(matrix, response: .matrixmulti(choices: [["A"]]))
        }
        let multi = QuestionBody.matrixmulti(columns: ["A"], rows: [MatrixMultiRow(text: "Row", answers: ["A"])])
        #expect(throws: ScoringError.self) {
            try Scoring.score(multi, response: .matrix(choices: ["A"]))
        }
        #expect(throws: ScoringError.self) {
            try Scoring.score(.unsupported(typeName: "hotspot"), response: nil)
        }
    }

    // The banner wording from `score.test.ts`: label, points line, and rule sentence.

    @Test func rulesExplainPlusMinusAndOrdering() {
        #expect(QuestionType.sata.scoringRule == "+1 for each correct choice, -1 for each wrong one")
        #expect(QuestionType.highlight.scoringRule == "+1 for each correct choice, -1 for each wrong one")
        #expect(QuestionType.matrixmulti.scoringRule == "+1 for each correct box, -1 for each wrong one")
        #expect(QuestionType.order.scoringRule == "items in the right position; full credit needs all of them")
        for type in [QuestionType.single, .priority, .match, .matrix, .cloze] {
            #expect(type.scoringRule == nil)
        }
    }

    @Test func labelsNameEachOutcome() throws {
        let single = QuestionBody.single(options: Self.options([0], count: 3))
        let sata = QuestionBody.sata(options: Self.options([0, 2], count: 3))
        #expect(try Scoring.score(single, response: .single(choice: 0)).label == "Correct")
        #expect(try Scoring.score(sata, response: .sata(picks: [0])).label == "Partly correct")
        #expect(try Scoring.score(sata, response: .sata(picks: [1])).label == "Not correct")
        #expect(try Scoring.score(sata, response: nil).label == "Not answered")
    }

    @Test func pointsShowForMultiPartAnswersOnly() throws {
        let sata = QuestionBody.sata(options: Self.options([0, 2], count: 3))
        #expect(try Scoring.score(sata, response: .sata(picks: [0])).pointsText(for: .sata) == "1 of 2 points")
        let highlight = QuestionBody.highlight(segments: Self.options([0, 2], count: 3))
        #expect(try Scoring.score(highlight, response: .highlight(picks: [0, 2])).pointsText(for: .highlight) == "2 of 2 points")
        let order = QuestionBody.order(items: ["A", "B"].map { OrderItem(text: $0) })
        #expect(try Scoring.score(order, response: .order(positions: [0, 1])).pointsText(for: .order) == "2 of 2 points")
        let single = try Scoring.score(.single(options: Self.options([0], count: 3)), response: .single(choice: 0))
        #expect(single.pointsText(for: .single) == nil)
        #expect(single.pointsText(for: .priority) == nil)
        #expect(try Scoring.score(sata, response: nil).pointsText(for: .sata) == nil)
    }

    @Test func savedAttemptGivesTheServersScore() throws {
        let saved = try QBankJSON.decoder.decode(SavedAttempt.self, from: Data("""
        {"clientAttemptId":"a","questionId":"q","courseId":"c","status":"partial","points":1,"maxPoints":3,
         "guessed":false,"answeredAt":"2026-10-13T00:02:35.438Z","inReview":true,"label":"Partly correct","replayed":false}
        """.utf8))
        let score = Score(saved)
        #expect(score == Score(points: 1, maxPoints: 3, status: .partial, answered: true))
        #expect(score.label == saved.label)
    }

    @Test func feedbackShowsTheServersWords() throws {
        // Words the phone would never write, so only the server's can pass.
        let saved = try QBankJSON.decoder.decode(SavedAttempt.self, from: Data("""
        {"clientAttemptId":"a","questionId":"q","courseId":"c","status":"partial","points":1,"maxPoints":3,
         "guessed":false,"answeredAt":"2026-10-13T00:02:35.438Z","inReview":true,"label":"Partly right",
         "pointsText":"1 point of 3","ruleText":"A new rule","replayed":false}
        """.utf8))
        let feedback = Feedback(saved)
        #expect(feedback.score == Score(points: 1, maxPoints: 3, status: .partial, answered: true))
        #expect(feedback.label == "Partly right")
        #expect(feedback.pointsText == "1 point of 3")
        #expect(feedback.ruleText == "A new rule")
    }

    @Test func feedbackOnThePhoneWordsItsOwnScore() throws {
        let sata = QuestionBody.sata(options: Self.options([0, 2], count: 3))
        let partly = Feedback(phone: try Scoring.score(sata, response: .sata(picks: [0])), type: .sata)
        #expect(partly.label == "Partly correct")
        #expect(partly.pointsText == "1 of 2 points")
        #expect(partly.ruleText == "+1 for each correct choice, -1 for each wrong one")
        let single = Feedback(phone: try Scoring.score(.single(options: Self.options([0], count: 3)), response: .single(choice: 1)), type: .single)
        #expect(single.label == "Not correct")
        #expect(single.pointsText == nil)
        #expect(single.ruleText == nil)
        let unknown = Feedback(phone: try Scoring.score(sata, response: .sata(picks: [0, 2])), type: nil)
        #expect(unknown.label == "Correct")
        #expect(unknown.pointsText == nil, "a format this version does not know adds no line")
    }
}
