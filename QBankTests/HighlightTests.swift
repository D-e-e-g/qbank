import Foundation
import QBankKit
import Testing
@testable import QBank

/// Marks the user makes on a question's words while working on it: press and drag to mark, tap a
/// mark to erase it, Clear highlights for the whole question, in yellow, blue or pink. They last
/// for the attempt on this device, as strikes do, and are never sent. Invented questions only.
@MainActor
struct HighlightTests {
    // MARK: Marks on one piece of text

    @Test func aMarkCoversItsWordsInThePensColor() {
        var highlights = Highlights()
        #expect(highlights.isEmpty)
        highlights.paint(4..<9, in: .stem, color: .yellow)
        #expect(highlights[.stem] == [Highlight(range: 4..<9, color: .yellow)])
        #expect(highlights[.ask] == [], "each piece of text has its own marks")
        #expect(!highlights.isEmpty)
    }

    @Test func touchingOrOverlappingMarksOfOneColorJoin() {
        var highlights = Highlights()
        highlights.paint(10..<15, in: .stem, color: .blue)
        highlights.paint(0..<5, in: .stem, color: .blue)
        highlights.paint(5..<8, in: .stem, color: .blue)
        #expect(highlights[.stem] == [Highlight(range: 0..<8, color: .blue), Highlight(range: 10..<15, color: .blue)])
        highlights.paint(6..<12, in: .stem, color: .blue)
        #expect(highlights[.stem] == [Highlight(range: 0..<15, color: .blue)])
    }

    @Test func draggingOverAMarkWithAnotherColorRepaintsWhatItCovers() {
        var highlights = Highlights()
        highlights.paint(0..<20, in: .stem, color: .yellow)
        highlights.paint(5..<10, in: .stem, color: .pink)
        #expect(highlights[.stem] == [
            Highlight(range: 0..<5, color: .yellow),
            Highlight(range: 5..<10, color: .pink),
            Highlight(range: 10..<20, color: .yellow),
        ])
        highlights.paint(0..<20, in: .stem, color: .blue)
        #expect(highlights[.stem] == [Highlight(range: 0..<20, color: .blue)], "a wider drag repaints all of it")
        highlights.paint(15..<25, in: .stem, color: .pink)
        #expect(highlights[.stem] == [Highlight(range: 0..<15, color: .blue), Highlight(range: 15..<25, color: .pink)])
    }

    @Test func aTapOnAMarkErasesThatMarkOnly() {
        var highlights = Highlights()
        highlights.paint(0..<5, in: .stem, color: .yellow)
        highlights.paint(10..<15, in: .stem, color: .blue)
        highlights.paint(0..<3, in: .answer(2), color: .pink)
        #expect(highlights.mark(at: 12, in: .stem) == Highlight(range: 10..<15, color: .blue))
        #expect(highlights.mark(at: 7, in: .stem) == nil)
        let between = highlights.erase(at: 7, in: .stem)
        #expect(!between, "a tap between marks erases nothing")
        let onBlue = highlights.erase(at: 12, in: .stem)
        #expect(onBlue)
        #expect(highlights[.stem] == [Highlight(range: 0..<5, color: .yellow)])
        #expect(highlights[.answer(2)] == [Highlight(range: 0..<3, color: .pink)])
        let atTheEnd = highlights.erase(at: 5, in: .stem)
        #expect(!atTheEnd, "the end of a mark is not in it")
    }

    @Test func clearRemovesEveryMarkOfTheQuestion() {
        var highlights = Highlights()
        highlights.paint(0..<5, in: .stem, color: .yellow)
        highlights.paint(0..<2, in: .tableCell(row: 1, column: 2), color: .blue)
        highlights.clear()
        #expect(highlights.isEmpty)
        #expect(highlights[.stem] == [])
    }

    @Test func anEmptyDragMarksNothing() {
        var highlights = Highlights()
        highlights.paint(4..<4, in: .stem, color: .yellow)
        #expect(highlights.isEmpty)
    }

    // MARK: Which words a drag covers

    @Test func aHoldMarksTheWholeWordUnderTheFinger() {
        let text = "The urine is cloudy and dark amber."
        #expect(WordSpan.covering(text, from: 15, to: 15) == 13..<19, "cloudy")
        #expect(WordSpan.covering(text, from: 13, to: 13) == 13..<19, "from its first letter")
    }

    @Test func aDragMarksEveryWordItCrossesEitherWay() {
        let text = "The urine is cloudy and dark amber."
        #expect(WordSpan.covering(text, from: 14, to: 31) == 13..<34, "cloudy and dark amber")
        #expect(WordSpan.covering(text, from: 31, to: 14) == 13..<34, "dragged backwards")
        #expect(WordSpan.covering(text, from: 12, to: 12) == nil, "a space between words marks nothing")
        #expect(WordSpan.covering(text, from: 34, to: 34) == 29..<34, "a hold on the period takes the word it ends")
        #expect(WordSpan.covering("“If you skip", from: 0, to: 0) == 1..<3, "a hold on an opening quote takes the word it opens")
        #expect(WordSpan.covering("Wait . here", from: 5, to: 5) == nil, "punctuation standing alone marks nothing")
    }

    @Test func aReadingIsMarkedWholeAndSentencePunctuationIsLeftOut() {
        let text = "BP 86/48, SpO₂ 93%, temp 38.9 °C. “Your provider ordered it.”"
        let span = { (word: String) -> Range<Int>? in
            let found = (text as NSString).range(of: word)
            return WordSpan.covering(text, from: found.location, to: found.location)
        }
        let range = { (word: String) -> Range<Int> in
            let found = (text as NSString).range(of: word)
            return found.location..<(found.location + found.length)
        }
        #expect(span("86/48") == range("86/48"), "the comma after it is left out")
        #expect(span("93%") == range("93%"))
        #expect(span("38.9") == range("38.9"))
        #expect(span("Your") == range("Your"), "the opening quote is left out")
        #expect(span("it.”") == range("it"))
    }

    @Test func offsetsCountUTF16AsTheTextViewDoes() {
        let text = "Temp 38.9 °C, café 🌡️ noted"
        let utf16 = Array(text.utf16)
        let noted = (text as NSString).range(of: "noted")
        #expect(WordSpan.covering(text, from: noted.location + 1, to: noted.location + 1) == noted.location..<(noted.location + noted.length))
        let cafe = (text as NSString).range(of: "café")
        #expect(WordSpan.covering(text, from: cafe.location, to: cafe.location) == cafe.location..<(cafe.location + cafe.length))
        #expect(utf16.count > text.count, "the emoji takes more than one unit")
    }

    // MARK: The pen keeps its color on this device

    @Test func thePenStartsYellowAndKeepsTheLastColor() {
        let defaults = TestApp.freshDefaults()
        let pen = HighlighterStore(defaults: defaults)
        #expect(pen.color == .yellow)
        pen.color = .pink
        #expect(HighlighterStore(defaults: defaults).color == .pink, "a new launch keeps the last color")
        #expect(HighlightColor.allCases == [.yellow, .blue, .pink])
        #expect(HighlightColor.allCases.map(\.name) == ["Yellow", "Blue", "Pink"])
    }

    // MARK: Practice

    @Test func practiceMarksStayAfterCheckAnswerAndAreNeverSent() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
            "POST /api/attempts": StubServer.Reply(
                status: 201, body: PracticeModelTests.saved(id: "attempt-1", question: "q-sata", status: "correct", points: 2, max: 2)
            ),
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        model.highlight(0..<4, in: .stem, color: .yellow)
        model.highlight(0..<1, in: .answer(1), color: .blue)
        #expect(model.attempt?.draft == .sata([]), "marking a choice's words does not pick it")
        #expect(!model.canCheck)
        model.update(.sata([0, 2]))
        await model.check()

        let sent = String(decoding: try #require(server.requests.last?.httpBody), as: UTF8.self).lowercased()
        #expect(!sent.contains("highlight") && !sent.contains("mark"), "marks are never sent")
        #expect(model.attempt?.highlights[.stem] == [Highlight(range: 0..<4, color: .yellow)], "marks stay after Check answer")
        model.highlight(5..<8, in: .ask, color: .pink)
        model.eraseHighlight(at: 0, in: .answer(1))
        #expect(model.attempt?.highlights[.ask] == [Highlight(range: 5..<8, color: .pink)], "she can still mark beside the rationale")
        #expect(model.attempt?.highlights[.answer(1)] == [])

        model.next()
        #expect(model.attempt?.highlights.isEmpty == true, "the next question starts clean")
        #expect(model.attempts[0].highlights[.stem] == [Highlight(range: 0..<4, color: .yellow)], "the first one keeps its marks for the run")
    }

    @Test func clearHighlightsClearsOnlyThisQuestion() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet())])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        model.highlight(0..<4, in: .stem, color: .yellow)
        model.highlight(0..<2, in: .ask, color: .blue)
        model.clearHighlights()
        #expect(model.attempt?.highlights.isEmpty == true)
    }

    @Test func startOverBeginsWithoutMarks() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(SetProgressTests.set(sitting: SetProgressTests.sitting([0]))),
            "POST /api/practice-sets/set1/start-over": .ok(#"{"ended":true}"#),
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        model.highlight(0..<4, in: .stem, color: .pink)
        await model.startOver()
        #expect(model.attempts.allSatisfy { $0.highlights.isEmpty })
    }

    @Test func theOwnersLookMarksNothing() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet())])
        let (model, app) = PracticeModelTests.model(server, account: .admin)
        await model.load()
        app.frozen.hideNote()
        model.highlight(0..<4, in: .stem, color: .yellow)
        #expect(app.frozen.noteID != nil, "marking answers with the note")
        #expect(model.attempt?.highlights.isEmpty == true)
    }

    // MARK: Exam

    @Test func examMarksStayWithASkippedQuestionAndAreNeverSent() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: StudyBodies.saved(question: "e1-q0", attempt: "attempt-1")),
        ])
        let model = ExamModelTests.model(server)
        await model.load()
        model.highlight(0..<3, in: .stem, color: .blue)
        model.highlight(0..<2, in: .answer(0), color: .pink)
        #expect(model.item?.draft == .single(nil), "marking a choice's words does not pick it")
        await model.skip()
        #expect(model.item?.highlights.isEmpty == true, "the next question starts clean")
        await model.skip()
        await model.skip()
        #expect(model.index == 0)
        #expect(model.item?.highlights[.stem] == [Highlight(range: 0..<3, color: .blue)], "her marks are there when she comes back")
        model.eraseHighlight(at: 1, in: .answer(0))
        #expect(model.item?.highlights[.answer(0)] == [])
        model.update(.single(1))
        await model.submit()
        let sent = String(decoding: try #require(server.requests.last?.httpBody), as: UTF8.self).lowercased()
        #expect(!sent.contains("highlight") && !sent.contains("mark"), "marks are never sent")
    }
}

/// The runner's strip: one step per question. Practice shows each result in the chart colors; a
/// timed exam shows answered and skipped only. Invented questions only.
@MainActor
struct RunnerStripTests {
    @Test func practiceLeavesEachResultOnTheStrip() async throws {
        let server = StubServer([
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
            "POST /api/attempts": StubServer.Reply(
                status: 201, body: PracticeModelTests.saved(id: "attempt-1", question: "q-sata", status: "partial", points: 1, max: 2)
            ),
        ])
        let (model, _) = PracticeModelTests.model(server)
        await model.load()
        #expect(model.strip == [.current, .open])
        model.update(.sata([0]))
        await model.check()
        #expect(model.strip == [.partial, .open])
        model.next()
        #expect(model.strip == [.partial, .current])
    }

    @Test func aTimedExamShowsAnsweredAndSkippedOnly() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: StudyBodies.saved(question: "e1-q0", attempt: "attempt-1")),
        ])
        let model = ExamModelTests.model(server)
        await model.load()
        #expect(model.strip == [.current, .open, .open])
        model.update(.single(0))
        await model.submit()
        #expect(model.strip == [.answered, .current, .open])
        await model.skip()
        #expect(model.strip == [.answered, .skipped, .current])
    }
}
