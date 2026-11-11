import Testing
@testable import QBank

/// The Debug fake's import check, in the server's words. A select-all question needs at least one
/// correct option, and every option may be correct.
@Suite("Fake import check")
struct FakeImportCheckTests {
    private static func file(options: String) -> String {
        #"{"title":"Invented","questions":[{"id":"Q1","type":"sata","stem":"Stem.","ask":"Which apply?","options":\#(options),"rationale":"Because.","takeaway":"Remember."}]}"#
    }

    @Test func allCorrectSelectAllIsAccepted() {
        let options = #"[{"t":"A","ok":true},{"t":"B","ok":true},{"t":"C","ok":true}]"#
        let check = FakeImportCheck(source: Self.file(options: options))
        #expect(check.ok)
        #expect(check.errors.isEmpty)
        #expect(check.questionCount == 1)
        #expect(check.formats.map(\.type) == [.sata])
    }

    @Test func selectAllWithNoCorrectOptionIsRefused() {
        let options = #"[{"t":"A"},{"t":"B"},{"t":"C"}]"#
        let check = FakeImportCheck(source: Self.file(options: options))
        #expect(check.errors == ["Question 1 (Q1): select-all needs at least one correct option"])
        #expect(!check.ok)
        #expect(check.questionCount == 0)
    }
}
