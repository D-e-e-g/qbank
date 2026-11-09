import Foundation
import Testing
@testable import QBankKit

/// A seeded generator, so shuffles in tests repeat.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("Models")
struct ModelTests {
    static func question(type: String, body: String, extra: String = "") throws -> Question {
        let json = """
        {"id": "q1", "publicId": "Q1", "position": 1, "type": "\(type)", "topic": "T", "cj": null,
         "stem": "S", "ask": "A", "rationale": "R", "takeaway": "K", "body": \(body), "terms": []\(extra)}
        """
        return try QBankJSON.decoder.decode(Question.self, from: Data(json.utf8))
    }

    @Test func unknownFormatIsKeptNotRejected() throws {
        let question = try Self.question(type: "hotspot", body: #"{"spots": [1, 2]}"#)
        #expect(question.type == nil)
        #expect(question.body == .unsupported(typeName: "hotspot"))
        let again = try QBankJSON.decoder.decode(Question.self, from: QBankJSON.encoder.encode(question))
        #expect(again == question)
        #expect(again.rawBody["spots"] == .array([.number(1), .number(2)]))
    }

    @Test func knownFormatWithABrokenBodyIsAnError() {
        #expect(throws: DecodingError.self) { try Self.question(type: "single", body: #"{"items": []}"#) }
        #expect(throws: DecodingError.self) { try Self.question(type: "cloze", body: #"{"cloze": {"text": "x"}}"#) }
    }

    @Test func matrixMultiDecodesAListOfColumnsAndKeepsAPlainLayout() throws {
        let question = try Self.question(
            type: "matrixmulti",
            body: #"{"columns":["Column A","Column B"],"rows":[{"t":"Finding","ans":["Column A","Column B"],"why":"Both"}]}"#
        )
        #expect(question.body == .matrixmulti(
            columns: ["Column A", "Column B"],
            rows: [MatrixMultiRow(text: "Finding", answers: ["Column A", "Column B"], why: "Both")]
        ))
        var generator = SeededGenerator(state: 1)
        #expect(Layout.make(for: question.body, using: &generator) == .plain)
        #expect(throws: DecodingError.self) {
            try Self.question(type: "matrix", body: #"{"columns":["Column A"],"rows":[{"t":"Finding","ans":["Column A"]}]}"#)
        }
    }

    @Test func matchWithoutDistractors() throws {
        let question = try Self.question(type: "match", body: #"{"pairs": [{"l": "A", "r": "B"}]}"#)
        #expect(question.body == .match(pairs: [MatchPair(left: "A", right: "B")], extra: []))
    }

    @Test func answerEncodingMatchesTheServerShapes() throws {
        let cases: [(AnswerResponse, String)] = [
            (.single(choice: 1), #"{"choice":1,"type":"single"}"#),
            (.priority(choice: 0), #"{"choice":0,"type":"priority"}"#),
            (.sata(picks: [0, 2]), #"{"picks":[0,2],"type":"sata"}"#),
            (.highlight(picks: []), #"{"picks":[],"type":"highlight"}"#),
            (.order(positions: [2, 0, 1]), #"{"positions":[2,0,1],"type":"order"}"#),
            (.match(choices: ["A", nil]), #"{"choices":["A",null],"type":"match"}"#),
            (.matrix(choices: [nil, "B"]), #"{"choices":[null,"B"],"type":"matrix"}"#),
            (.matrixmulti(choices: [["Column A"], []]), #"{"choices":[["Column A"],[]],"type":"matrixmulti"}"#),
            (.cloze(choices: [1, nil]), #"{"choices":[1,null],"type":"cloze"}"#),
        ]
        for (response, json) in cases {
            #expect(String(decoding: try QBankJSON.encoder.encode(response), as: UTF8.self) == json)
            #expect(try QBankJSON.decoder.decode(AnswerResponse.self, from: Data(json.utf8)) == response)
        }
    }

    @Test func submissionLeavesOutWhatItDoesNotHave() throws {
        let submission = AttemptSubmission(clientAttemptID: "a", questionID: "q", response: .single(choice: 0))
        let json = String(decoding: try QBankJSON.encoder.encode(submission), as: UTF8.self)
        #expect(json == #"{"clientAttemptId":"a","guessed":false,"questionId":"q","response":{"choice":0,"type":"single"}}"#)
    }

    @Test func newAttemptIDsAreLowercaseUUIDs() {
        let id = AttemptSubmission.newID()
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())
        #expect(AttemptSubmission(questionID: "q", response: .single(choice: 0)).clientAttemptID != id)
    }

    @Test func layoutsRoundTrip() throws {
        let layouts: [Layout] = [.options(order: [2, 0, 1]), .order(start: [1, 0]), .match(choices: ["B", "A"]), .cloze(blanks: [[1, 0], [2, 0, 1]]), .plain]
        for layout in layouts {
            #expect(try QBankJSON.decoder.decode(Layout.self, from: QBankJSON.encoder.encode(layout)) == layout)
        }
        #expect(String(decoding: try QBankJSON.encoder.encode(Layout.plain), as: UTF8.self) == #"{"kind":"plain"}"#)
    }

    @Test func freshLayoutsShuffleEveryFormat() throws {
        let set = try Fixture.load("practice-set").decodeBody(PracticeSet.self)
        var generator = SeededGenerator(state: 42)
        for question in set.questions {
            let layout = Layout.make(for: question.body, using: &generator)
            switch (question.body, layout) {
            case (.single(let options), .options(let order)), (.priority(let options), .options(let order)), (.sata(let options), .options(let order)):
                #expect(order.sorted() == Array(options.indices))
            case (.order(let items), .order(let start)):
                #expect(start.sorted() == Array(items.indices))
            case (.match(let pairs, let extra), .match(let choices)):
                #expect(choices.sorted() == (pairs.map(\.right) + extra.map(\.right)).sorted())
            case (.cloze(let cloze), .cloze(let blanks)):
                #expect(blanks.map { $0.sorted() } == cloze.blanks.map { Array($0.options.indices) })
            case (.highlight, .plain), (.matrix, .plain):
                break
            default:
                Issue.record("Layout \(layout) does not fit \(question.typeName)")
            }
        }
    }

    @Test func orderingNeverOpensSolved() {
        let body = QuestionBody.order(items: [OrderItem(text: "A"), OrderItem(text: "B")])
        for seed in 0..<50 {
            var generator = SeededGenerator(state: UInt64(seed))
            #expect(Layout.make(for: body, using: &generator) == .order(start: [1, 0]))
        }
    }

    @Test func timestampsKeepTheirMilliseconds() throws {
        for text in ["2026-10-13T00:02:35.395Z", "2026-10-13T00:02:35.001Z", "2026-10-13T00:02:35.999Z", "1969-12-31T23:59:59.500Z"] {
            let date = try #require(QBankJSON.parseDate(text))
            #expect(QBankJSON.formatDate(date) == text)
        }
        #expect(QBankJSON.parseDate("2026-10-13T00:02:35Z") != nil)
        #expect(QBankJSON.parseDate("2026-10-13") == nil)
    }

    /// The make-questions job routes send Postgres's own text for a timestamp.
    @Test func postgresTimestampsReadAsTheSameInstant() throws {
        let cases = [
            ("2026-10-13 00:02:35.395+00", "2026-10-13T00:02:35.395Z"),
            ("2026-10-12 19:02:35.395-05", "2026-10-13T00:02:35.395Z"),
            ("2026-10-13 05:32:35.395+05:30", "2026-10-13T00:02:35.395Z"),
            ("2026-10-13 00:02:35.39+00", "2026-10-13T00:02:35.390Z"),
            ("2026-10-13 00:02:35.395123+00", "2026-10-13T00:02:35.395Z"),
            ("2026-10-13 00:02:35+00", "2026-10-13T00:02:35.000Z"),
        ]
        for (postgres, iso) in cases {
            let date = try #require(QBankJSON.parseDate(postgres), "\(postgres)")
            #expect(QBankJSON.formatDate(date) == iso, "\(postgres)")
        }
        #expect(QBankJSON.parseDate("2026-10-13 00:02:35") == nil)
    }
}

@Suite("Question media")
struct MediaTests {
    static let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    static func images(_ json: String) throws -> [QuestionImage] {
        QuestionImage.read(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    static func table(_ json: String) throws -> QuestionTable? {
        QuestionTable(json: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @Test func tablePadsShortRowsAndWritesNumbersPlainly() throws {
        let table = try Self.table(#"{"caption": "  Labs ", "rows": [["Na", 140, 3.5, true, null], ["K"]]}"#)
        #expect(table == QuestionTable(caption: "Labs", head: [], rows: [["Na", "140", "3.5", "true", ""], ["K", "", "", "", ""]]))
    }

    @Test func tableThatCannotBeDrawnIsLeftOut() throws {
        #expect(try Self.table(#"{"rows": []}"#) == nil)
        #expect(try Self.table(#"{"rows": [[{"x": 1}]]}"#) == nil)
        #expect(try Self.table(#"{"caption": 3, "rows": [["a"]]}"#) == nil)
        #expect(try Self.table(#"{"head": "x", "rows": [["a"]]}"#) == nil)
        #expect(try Self.table(#"{"rows": [[]]}"#) == nil)
        #expect(QuestionTable(json: nil) == nil)
    }

    @Test func pngDataURL() throws {
        let images = try Self.images(#"[{"src": "\#(Self.png)", "alt": " A pixel ", "caption": ""}]"#)
        let image = try #require(images.first)
        #expect(image.alt == "A pixel")
        #expect(image.caption == nil)
        #expect(image.placement == .stem)
        #expect(image.file?.mediaType == "image/png")
        #expect(image.file?.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func unsafeOrBrokenImagesAreLeftOut() throws {
        let cases = [
            #"[{"src": "\#(Self.png)"}]"#,
            #"[{"src": "\#(Self.png)", "alt": "x", "svg": "<svg/>"}]"#,
            #"[{"src": "\#(Self.png)", "alt": "x", "at": "footer"}]"#,
            #"[{"src": "https://example.com/a.png", "alt": "x"}]"#,
            #"[{"src": "data:image/gif;base64,R0lGODlh", "alt": "x"}]"#,
            #"[{"src": "data:image/png,rawbytes", "alt": "x"}]"#,
            #"[{"src": "data:image/png;base64,/9j/4AAQSkZJRg==", "alt": "x"}]"#,
            #"[{"src": "data:image/png;base64,not base64!", "alt": "x"}]"#,
            #"[{"svg": "<svg><script>alert(1)</script></svg>", "alt": "x"}]"#,
            #"[{"svg": "<svg onload=\"x()\"></svg>", "alt": "x"}]"#,
            #"[{"svg": "<svg><image href=\"https://example.com/a.png\"/></svg>", "alt": "x"}]"#,
            #"[{"svg": "<svg style=\"background: url(https://example.com/a.png)\"></svg>", "alt": "x"}]"#,
            #"[{"svg": "<div>not svg</div>", "alt": "x"}]"#,
            #"["not an object"]"#,
        ]
        for json in cases {
            #expect(try Self.images(json).isEmpty, "\(json)")
        }
    }

    @Test func safeSVGIsKept() throws {
        let images = try Self.images(##"[{"svg": "<svg><use href=\"#a\"/><rect fill=\"url(#g)\"/></svg>", "alt": "x", "at": "rationale"}]"##)
        #expect(images.first?.placement == .rationale)
        #expect(images.first?.file?.mediaType == "image/svg+xml")
    }

    @Test func atMostFourImages() throws {
        let one = #"{"src": "\#(Self.png)", "alt": "x"}"#
        #expect(try Self.images("[\(Array(repeating: one, count: 6).joined(separator: ","))]").count == 4)
    }

    @Test func oversizedImageIsLeftOut() throws {
        let big = String(repeating: "A", count: (QuestionImage.maxBytes / 3 + 10) * 4)
        #expect(try Self.images(#"[{"svg": "<svg>\#(big)</svg>", "alt": "x"}]"#).isEmpty)
    }
}
