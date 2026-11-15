import Foundation
import Testing
import UIKit
@testable import QBank

/// Marking with no hold first: a swipe along the words marks them, a swipe up or down scrolls, and
/// one that starts beside the words scrolls. The Apple Pencil and the mouse mark in any direction.
/// The eraser takes marks off the words it swipes over. XCTest cannot make a Pencil's touch, so the
/// Pencil is tested here, from the reading of its swipe to the words it marks. Invented text only.
@MainActor
struct HighlightSwipeTests {
    // MARK: Reading a swipe

    @Test func aFingerSwipingAlongTheWordsMarksAtOnce() {
        let right = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: 12, height: 2))
        let left = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: -12, height: -3))
        #expect(right == .marks)
        #expect(left == .marks, "right to left marks too")
        let slanted = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: 10, height: 6))
        #expect(slanted == .marks, "a hand does not draw a level line")
    }

    @Test func aFingerSwipingUpOrDownScrollsEvenOnWords() {
        let up = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: 1, height: -12))
        let down = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: -3, height: 12))
        #expect(up == .scrolls)
        #expect(down == .scrolls)
        let diagonal = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: 9, height: 9))
        #expect(diagonal == .scrolls, "halfway between, the page scrolls")
    }

    @Test func aSwipeIsReadOnlyOnceItHasTravelled() {
        let still = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 1, travel: CGSize(width: 6, height: 1))
        #expect(still == .undecided, "a tap that slips a little is still a tap")
        let pencil = MarkSwipe.verdict(pointer: .pencil, onWords: true, fingers: 0, travel: CGSize(width: 2, height: 1))
        #expect(pencil == .undecided)
    }

    @Test func aSwipeThatStartsBesideTheWordsScrolls() {
        for pointer in [MarkSwipe.Pointer.finger, .pencil, .mouse] {
            let beside = MarkSwipe.verdict(pointer: pointer, onWords: false, fingers: 1, travel: CGSize(width: 30, height: 0))
            #expect(beside == .scrolls)
            let atOnce = MarkSwipe.verdict(pointer: pointer, onWords: false, fingers: 1, travel: .zero)
            #expect(atOnce == .scrolls, "known the moment it touches down")
        }
    }

    @Test func twoFingersScroll() {
        let two = MarkSwipe.verdict(pointer: .finger, onWords: true, fingers: 2, travel: CGSize(width: 30, height: 0))
        #expect(two == .scrolls)
        let resting = MarkSwipe.verdict(pointer: .pencil, onWords: true, fingers: 1, travel: CGSize(width: 30, height: 0))
        #expect(resting == .marks, "a hand resting on the screen does not stop the Pencil")
    }

    @Test func thePencilAndTheMouseMarkInAnyDirection() {
        for pointer in [MarkSwipe.Pointer.pencil, .mouse] {
            for travel in [CGSize(width: 5, height: 0), CGSize(width: -5, height: 1), CGSize(width: 0, height: 5), CGSize(width: 1, height: -5), CGSize(width: 3, height: 3)] {
                let verdict = MarkSwipe.verdict(pointer: pointer, onWords: true, fingers: 0, travel: travel)
                #expect(verdict == .marks, "\(pointer) going \(travel)")
            }
        }
        #expect(MarkSwipe.Pointer(.pencil) == .pencil)
        #expect(MarkSwipe.Pointer(.indirectPointer) == .mouse)
        #expect(MarkSwipe.Pointer(.direct) == .finger)
        #expect(MarkSwipe.Pointer.pencil.slop < MarkSwipe.Pointer.finger.slop, "the Pencil's tip is steadier than a finger")
    }

    // MARK: The words a swipe marks

    /// Two lines of even letters, so a point lands on a known letter.
    @MainActor
    private struct Page {
        static let text = "The urine is cloudy and dark amber. Output is 90 mL in four hours."
        let view = MarkableTextView()
        let letter: CGFloat
        let line: CGFloat = 24

        init() {
            let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            letter = ("m" as NSString).size(withAttributes: [.font: font]).width
            view.content = MarkableTextView.Content(text: Self.text, font: font, lineHeight: line)
            // Room for "The urine is cloudy and dark amber." and no more, so the rest wraps.
            let size = view.fittingSize(width: ceil(letter * 36))
            view.frame = CGRect(origin: .zero, size: size)
        }

        /// The middle of a letter of the first line, or of the second.
        func point(_ column: CGFloat, line row: CGFloat = 0) -> CGPoint {
            CGPoint(x: (column + 0.5) * letter, y: (row + 0.5) * line)
        }

        static func range(_ words: String) -> Range<Int> {
            let found = (text as NSString).range(of: words)
            return found.location..<(found.location + found.length)
        }
    }

    @Test func thePencilMarksFromTheWordItPressedToTheWordItReached() {
        let page = Page()
        var swiped: [Range<Int>] = []
        page.view.onSwipe = { swiped.append($0) }
        #expect(page.view.frame.height == 2 * page.line, "the text takes two lines")
        // Read as marking after a few points of travel, in whatever direction it goes.
        let verdict = MarkSwipe.verdict(pointer: .pencil, onWords: page.view.isOnWords(page.point(14)), fingers: 0, travel: CGSize(width: 4, height: 3))
        #expect(verdict == .marks)

        page.view.beginMark(at: page.point(14))
        page.view.extendMark(to: page.point(26))
        page.view.endMark()
        #expect(swiped == [Page.range("cloudy and dark")], "whole words, from the one pressed")

        // Down a line: the Pencil sets off in any direction.
        page.view.beginMark(at: page.point(30))
        page.view.extendMark(to: page.point(11, line: 1))
        page.view.endMark()
        #expect(swiped.last == Page.range("amber. Output is 90"))

        // Backwards, and a cancelled swipe marks nothing.
        page.view.beginMark(at: page.point(26))
        page.view.extendMark(to: page.point(5))
        page.view.endMark()
        #expect(swiped.last == Page.range("urine is cloudy and dark"))
        page.view.beginMark(at: page.point(2))
        page.view.extendMark(to: page.point(8))
        page.view.endMark(cancelled: true)
        #expect(swiped.count == 3)
    }

    @Test func theRoomAfterAShortLastLineIsBesideTheWords() {
        let page = Page()
        #expect(page.view.isOnWords(page.point(0)))
        #expect(page.view.isOnWords(page.point(12)), "a space between two words is on the line")
        #expect(page.view.isOnWords(page.point(34)))
        #expect(page.view.isOnWords(page.point(29, line: 1)), "the last word of the last line")
        #expect(!page.view.isOnWords(page.point(33, line: 1)), "past the end of the last line")
        #expect(!page.view.isOnWords(CGPoint(x: 10, y: -4)))
        #expect(!page.view.isOnWords(CGPoint(x: 10, y: 2 * page.line + 4)))
    }

    // MARK: The eraser

    @Test func theEraserCleansTheWordsItSwipesOver() {
        var highlights = Highlights()
        highlights.paint(0..<20, in: .stem, color: .yellow)
        highlights.paint(30..<40, in: .stem, color: .blue)
        highlights.paint(0..<5, in: .ask, color: .pink)

        let middle = highlights.erase(8..<12, in: .stem)
        #expect(middle)
        #expect(highlights[.stem] == [
            Highlight(range: 0..<8, color: .yellow),
            Highlight(range: 12..<20, color: .yellow),
            Highlight(range: 30..<40, color: .blue),
        ], "a mark keeps the words on either side of the swipe")

        let across = highlights.erase(15..<35, in: .stem)
        #expect(across)
        #expect(highlights[.stem] == [
            Highlight(range: 0..<8, color: .yellow),
            Highlight(range: 12..<15, color: .yellow),
            Highlight(range: 35..<40, color: .blue),
        ], "one swipe cleans every mark it crosses")

        let clean = highlights.erase(20..<30, in: .stem)
        #expect(!clean, "nothing to erase on clean words")
        let touching = highlights.erase(8..<12, in: .stem)
        #expect(!touching, "a swipe that ends where a mark starts leaves it")
        let empty = highlights.erase(3..<3, in: .stem)
        #expect(!empty)

        highlights.erase(0..<40, in: .stem)
        #expect(highlights[.stem] == [])
        #expect(!highlights.isEmpty, "the other text keeps its marks")
        highlights.erase(0..<5, in: .ask)
        #expect(highlights.isEmpty)
    }

    @Test func thePenKeepsTheEraserInHandAndComesBackToItsColor() {
        let defaults = TestApp.freshDefaults()
        let pen = HighlighterStore(defaults: defaults)
        #expect(!pen.isErasing)
        #expect(pen.toolName == "Yellow")
        pen.pick(.blue)
        pen.isErasing = true
        #expect(pen.toolName == "Eraser")
        let relaunched = HighlighterStore(defaults: defaults)
        #expect(relaunched.isErasing, "a new launch keeps the eraser in hand")
        #expect(relaunched.color == .blue, "and the color the pen had")
        relaunched.pick(.pink)
        #expect(!relaunched.isErasing, "choosing a color goes back to highlighting")
        #expect(HighlighterStore(defaults: defaults).toolName == "Pink")
    }

    @Test func theEraserWorksOnPracticeAndExamQuestionsAndIsNeverSent() async throws {
        let practiceServer = StubServer([
            "GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet()),
            "POST /api/attempts": StubServer.Reply(
                status: 201, body: PracticeModelTests.saved(id: "attempt-1", question: "q-sata", status: "correct", points: 2, max: 2)
            ),
        ])
        let (practice, _) = PracticeModelTests.model(practiceServer)
        await practice.load()
        practice.highlight(0..<10, in: .stem, color: .yellow)
        practice.eraseHighlights(4..<10, in: .stem)
        #expect(practice.attempt?.highlights[.stem] == [Highlight(range: 0..<4, color: .yellow)])
        practice.update(.sata([0, 2]))
        await practice.check()
        let sent = String(decoding: try #require(practiceServer.requests.last?.httpBody), as: UTF8.self).lowercased()
        #expect(!sent.contains("highlight") && !sent.contains("mark") && !sent.contains("eras"), "marks and erasing are never sent")
        practice.eraseHighlights(0..<4, in: .stem)
        #expect(practice.attempt?.highlights.isEmpty == true, "the eraser still works beside the rationale")

        let exam = ExamModelTests.model(StubServer(["GET /api/exams/e1": .ok(StudyBodies.exam())]))
        await exam.load()
        exam.highlight(0..<10, in: .answer(0), color: .pink)
        exam.eraseHighlights(0..<6, in: .answer(0))
        #expect(exam.item?.highlights[.answer(0)] == [Highlight(range: 6..<10, color: .pink)])
        #expect(exam.item?.draft == .single(nil), "erasing on a choice's words does not pick it")
    }

    @Test func theOwnersLookErasesNothing() async throws {
        let server = StubServer(["GET /api/practice-sets/set1": .ok(PracticeModelTests.practiceSet())])
        let (model, app) = PracticeModelTests.model(server, account: .admin)
        await model.load()
        app.frozen.hideNote()
        model.eraseHighlights(0..<4, in: .stem)
        #expect(app.frozen.noteID != nil, "erasing answers with the note")
    }
}
