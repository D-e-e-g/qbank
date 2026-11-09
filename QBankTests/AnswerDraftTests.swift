import QBankKit
import Testing
@testable import QBank

/// Her in-progress answer, as the web runner's `model.ts` keeps it.
struct AnswerDraftTests {
    static func options(_ count: Int) -> [QuestionOption] {
        (0..<count).map { QuestionOption(text: "Option \($0)", isCorrect: $0 == 0) }
    }

    @Test func startsEmptyAndOrderingStartsWhereItOpened() {
        #expect(AnswerDraft(body: .single(options: Self.options(3)), layout: .plain) == .single(nil))
        #expect(AnswerDraft(body: .priority(options: Self.options(3)), layout: .plain) == .priority(nil))
        #expect(AnswerDraft(body: .sata(options: Self.options(3)), layout: .plain) == .sata([]))
        #expect(AnswerDraft(body: .highlight(segments: Self.options(3)), layout: .plain) == .highlight([]))
        let items = ["A", "B", "C"].map { OrderItem(text: $0) }
        #expect(AnswerDraft(body: .order(items: items), layout: .order(start: [2, 0, 1])) == .order([2, 0, 1]))
        #expect(AnswerDraft(body: .order(items: items), layout: .plain) == .order([0, 1, 2]))
        let pairs = [MatchPair(left: "L1", right: "R1"), MatchPair(left: "L2", right: "R2")]
        #expect(AnswerDraft(body: .match(pairs: pairs, extra: []), layout: .plain) == .match([nil, nil]))
        let rows = [MatrixRow(text: "Row", answer: "Yes")]
        #expect(AnswerDraft(body: .matrix(columns: ["Yes", "No"], rows: rows), layout: .plain) == .matrix([nil]))
        let multi = QuestionBody.matrixmulti(columns: ["A", "B"], rows: [MatrixMultiRow(text: "One", answers: ["A"]), MatrixMultiRow(text: "Two", answers: ["B"])])
        #expect(AnswerDraft(body: multi, layout: .plain) == .matrixmulti([[], []]))
        let cloze = Cloze(text: "{0} {1}", blanks: [ClozeBlank(options: ["a"], answer: 0), ClozeBlank(options: ["b"], answer: 0)])
        #expect(AnswerDraft(body: .cloze(cloze), layout: .plain) == .cloze([nil, nil]))
        #expect(AnswerDraft(body: .unsupported(typeName: "hotspot"), layout: .plain) == .unsupported)
    }

    @Test func checkWaitsUntilEveryPartIsFilledButOrderingAlwaysCounts() {
        #expect(AnswerDraft.single(nil).response == nil)
        #expect(AnswerDraft.single(2).response == .single(choice: 2))
        #expect(AnswerDraft.priority(1).response == .priority(choice: 1))
        #expect(AnswerDraft.sata([]).response == nil)
        #expect(AnswerDraft.sata([3, 1]).response == .sata(picks: [3, 1]))
        #expect(AnswerDraft.highlight([]).response == nil)
        #expect(AnswerDraft.highlight([0]).response == .highlight(picks: [0]))
        #expect(AnswerDraft.order([1, 0]).response == .order(positions: [1, 0]))
        #expect(AnswerDraft.match(["R1", nil]).response == nil)
        #expect(AnswerDraft.match(["R2", "R1"]).response == .match(choices: ["R2", "R1"]))
        #expect(AnswerDraft.matrix([nil]).response == nil)
        #expect(AnswerDraft.matrix(["No"]).response == .matrix(choices: ["No"]))
        #expect(AnswerDraft.matrixmulti([["A"], []]).response == nil)
        #expect(AnswerDraft.matrixmulti([["A"], ["B"]]).response == .matrixmulti(choices: [["A"], ["B"]]))
        #expect(AnswerDraft.cloze([0, nil]).response == nil)
        #expect(AnswerDraft.cloze([0, 2]).response == .cloze(choices: [0, 2]))
        #expect(AnswerDraft.unsupported.response == nil)
    }

    @Test func pickingReplacesOneAnswerAndTogglesMany() {
        #expect(AnswerDraft.single(0).picking(2) == .single(2))
        #expect(AnswerDraft.priority(nil).picking(1) == .priority(1))
        #expect(AnswerDraft.sata([0]).picking(2) == .sata([0, 2]))
        #expect(AnswerDraft.sata([0, 2]).picking(0) == .sata([2]))
        #expect(AnswerDraft.highlight([1]).picking(1) == .highlight([]))
        #expect(AnswerDraft.order([0, 1]).picking(1) == .order([0, 1]), "ordering does not pick")
        #expect(AnswerDraft.sata([2, 0]).picked == [2, 0])
        #expect(AnswerDraft.single(nil).picked == [])
    }

    @Test func strikingAChoiceUnpicksItAndStrikingAgainRestoresIt() {
        var struck: Set<Int> = []
        #expect(AnswerDraft.single(1).striking(1, in: &struck) == .single(nil), "her pick is unpicked")
        #expect(struck == [1])
        #expect(AnswerDraft.single(nil).striking(1, in: &struck) == .single(nil), "restoring does not pick it again")
        #expect(struck == [])
        #expect(AnswerDraft.priority(0).striking(2, in: &struck) == .priority(0), "another choice stays picked")
        #expect(struck == [2])
        struck = []
        #expect(AnswerDraft.sata([0, 2, 3]).striking(2, in: &struck) == .sata([0, 3]))
        #expect(struck == [2])
        #expect(AnswerDraft.sata([0]).striking(2, in: &struck) == .sata([0]))
        #expect(struck == [])
    }

    @Test func onlyChoiceListsCanBeStruck() {
        #expect(AnswerDraft.single(nil).canStrike)
        #expect(AnswerDraft.priority(nil).canStrike)
        #expect(AnswerDraft.sata([]).canStrike)
        for draft in [AnswerDraft.highlight([1]), .order([0, 1]), .match([nil]), .matrix([nil]), .matrixmulti([[]]), .cloze([nil]), .unsupported] {
            var struck: Set<Int> = []
            #expect(!draft.canStrike)
            #expect(draft.striking(1, in: &struck) == draft)
            #expect(struck.isEmpty, "\(draft)")
        }
    }

    @Test func movingSwapsNeighboursAndDragsAcross() {
        let draft = AnswerDraft.order([0, 1, 2, 3])
        #expect(draft.moving(at: 1, by: -1) == .order([1, 0, 2, 3]))
        #expect(draft.moving(at: 2, by: 1) == .order([0, 1, 3, 2]))
        #expect(draft.moving(at: 0, by: -1) == draft, "the top row cannot move up")
        #expect(draft.moving(at: 3, by: 1) == draft, "the bottom row cannot move down")
        #expect(draft.moving(from: 0, to: 3) == .order([1, 2, 3, 0]))
        #expect(draft.moving(from: 3, to: 1) == .order([0, 3, 1, 2]))
        #expect(draft.moving(from: 2, to: 2) == draft)
        #expect(draft.moving(from: 5, to: 0) == draft)
    }

    @Test func choosingFillsOneRowOrBlank() {
        #expect(AnswerDraft.match([nil, nil]).choosing("R2", at: 1) == .match([nil, "R2"]))
        #expect(AnswerDraft.match(["R1"]).choosing(nil, at: 0) == .match([nil]))
        #expect(AnswerDraft.matrix([nil, nil]).choosing("Yes", at: 0) == .matrix(["Yes", nil]))
        #expect(AnswerDraft.matrix([nil]).choosing("Yes", at: 4) == .matrix([nil]))
        #expect(AnswerDraft.matrixmulti([[]]).choosing("A", at: 0) == .matrixmulti([[]]))
        #expect(AnswerDraft.matrixmulti([[], []]).checking("A", at: 0) == .matrixmulti([["A"], []]))
        #expect(AnswerDraft.matrixmulti([["A"], ["B"]]).checking("A", at: 0) == .matrixmulti([[], ["B"]]))
        #expect(AnswerDraft.matrixmulti([["A"], ["B"]]).checking("A", at: 0).checking("B", at: 0) == .matrixmulti([["B"], ["B"]]))
        #expect(AnswerDraft.matrixmulti([["A"]]).checking("B", at: 3) == .matrixmulti([["A"]]))
        #expect(AnswerDraft.cloze([nil, nil]).choosing(option: 2, forBlank: 1) == .cloze([nil, 2]))
        #expect(AnswerDraft.cloze([nil]).choosing(option: 2, forBlank: 3) == .cloze([nil]))
    }

    @Test func clozeSentenceSplitsAroundItsBlanks() {
        #expect(ClozePart.parse("Give {0} before {1}.") == [.text("Give "), .blank(0), .text(" before "), .blank(1), .text(".")])
        #expect(ClozePart.parse("{0}") == [.blank(0)])
        #expect(ClozePart.parse("No blanks here") == [.text("No blanks here")])
        #expect(ClozePart.parse("First {0}.\nThen {1}") == [.text("First "), .blank(0), .text("."), .lineBreak, .text("Then "), .blank(1)])
        #expect(ClozePart.parse("{10} and {x}") == [.blank(10), .text(" and {x}")])
    }

    @Test func revealTagsUseTheWebsWords() {
        #expect(RevealState(selected: true, correct: true) == .correct)
        #expect(RevealState(selected: true, correct: false) == .wrong)
        #expect(RevealState(selected: false, correct: true) == .missed)
        #expect(RevealState(selected: false, correct: false) == .dim)
        #expect(RevealState.correct.tag == "Your answer - Correct")
        #expect(RevealState.wrong.tag == "Your answer - Not correct")
        #expect(RevealState.missed.tag == "Missed")
        #expect(RevealState.dim.tag == nil)
    }

    @Test func savedShufflesThatDoNotFitFallBackToTheStoredOrder() {
        #expect(Layout.options(order: [2, 0, 1]).optionOrder(count: 3) == [2, 0, 1])
        #expect(Layout.options(order: [2, 0]).optionOrder(count: 3) == [0, 1, 2])
        #expect(Layout.plain.optionOrder(count: 2) == [0, 1])
        let pairs = [MatchPair(left: "L", right: "R1")]
        let extra = [MatchExtra(right: "R2")]
        #expect(Layout.match(choices: ["R2", "R1"]).matchChoices(pairs: pairs, extra: extra) == ["R2", "R1"])
        #expect(Layout.match(choices: ["R1", "R9"]).matchChoices(pairs: pairs, extra: extra) == ["R1", "R2"])
        let cloze = Cloze(text: "{0} {1}", blanks: [ClozeBlank(options: ["a", "b"], answer: 0), ClozeBlank(options: ["c", "d"], answer: 1)])
        #expect(Layout.cloze(blanks: [[1, 0], [0, 0]]).clozeOrders(cloze) == [[1, 0], [0, 1]])
    }

    @Test func aSentAnswerReadsBackForItsFormatOnly() {
        let options = [QuestionOption(text: "A", isCorrect: true), QuestionOption(text: "B", isCorrect: false)]
        #expect(AnswerDraft(response: .single(choice: 1), body: .single(options: options)) == .single(1))
        #expect(AnswerDraft(response: .sata(picks: [0, 1]), body: .sata(options: options)) == .sata([0, 1]))
        #expect(AnswerDraft(response: .single(choice: 1), body: .sata(options: options)) == nil, "another format")
        let items = [OrderItem(text: "1"), OrderItem(text: "2"), OrderItem(text: "3")]
        #expect(AnswerDraft(response: .order(positions: [2, 0, 1]), body: .order(items: items)) == .order([2, 0, 1]))
        #expect(AnswerDraft(response: .order(positions: [0, 0, 1]), body: .order(items: items)) == nil, "not every item once")
        let pairs = [MatchPair(left: "L1", right: "R1"), MatchPair(left: "L2", right: "R2")]
        #expect(AnswerDraft(response: .match(choices: ["R2", nil]), body: .match(pairs: pairs, extra: [])) == .match(["R2", nil]))
        #expect(AnswerDraft(response: .match(choices: ["R2"]), body: .match(pairs: pairs, extra: [])) == nil)
        let rows = [MatrixRow(text: "r", answer: "Yes")]
        #expect(AnswerDraft(response: .matrix(choices: ["No"]), body: .matrix(columns: ["Yes", "No"], rows: rows)) == .matrix(["No"]))
        let multi = QuestionBody.matrixmulti(columns: ["A", "B"], rows: [MatrixMultiRow(text: "One", answers: ["A"]), MatrixMultiRow(text: "Two", answers: ["A", "B"])])
        #expect(AnswerDraft(response: .matrixmulti(choices: [["A"], []]), body: multi) == .matrixmulti([["A"], []]))
        #expect(AnswerDraft(response: .matrixmulti(choices: [["A"]]), body: multi) == nil)
        let cloze = Cloze(text: "{0}", blanks: [ClozeBlank(options: ["a", "b"], answer: 0)])
        #expect(AnswerDraft(response: .cloze(choices: [1]), body: .cloze(cloze)) == .cloze([1]))
    }
}
