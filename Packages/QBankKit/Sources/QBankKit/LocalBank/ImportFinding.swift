import Foundation

/// A rule of the question file format, named by the code its issues carry: the server's `ISSUE_RULES`
/// (`packages/questions/src/format.ts`), which the contract's `x-question-format` lists.
enum FormatRule: String, CaseIterable {
    // The file as a whole.
    case notJSON = "not_json"
    case noQuestions = "no_questions"
    case badKind = "bad_kind"

    // A question as a whole.
    case notAnObject = "not_an_object"
    case unknownType = "unknown_type"
    case missingField = "missing_field"
    /// A field the file carries on another question, missing on this one.
    case missingUsedField = "missing_field_used_elsewhere"
    case notText = "not_text"
    case twinOfNotAnID = "twin_of_not_an_id"
    case twinOfIgnored = "twin_of_ignored"
    case termUndefined = "term_undefined"

    // The question types.
    case optionsMin = "options_min"
    case optionNeedsText = "option_needs_text"
    case exactlyOneCorrect = "exactly_one_correct"
    case sataNeedsCorrect = "sata_needs_correct"
    case itemsShape = "items_shape"
    case pairsShape = "pairs_shape"
    case matrixShape = "matrix_shape"
    case matrixRow = "matrix_row"
    case matrixCatchAll = "matrix_catch_all"
    case segmentsShape = "segments_shape"
    case clozeHoles = "cloze_holes"
    case clozeBlank = "cloze_blank"
    case duplicateColumn = "duplicate_column"
    case matrixMultiShape = "matrixmulti_shape"
    case matrixMultiRow = "matrixmulti_row"
    case matrixMultiNoRight = "matrixmulti_no_right"
    case matrixMultiAnsName = "matrixmulti_ans_name"
    case matrixMultiAnsTwice = "matrixmulti_ans_twice"
    case matrixMultiAllRight = "matrixmulti_all_right"
    case matrixMultiAsk = "matrixmulti_ask"

    // Tables and images.
    case tableShape = "table_shape"
    case tableCaption = "table_caption"
    case tableHead = "table_head"
    case imagesNotList = "images_not_list"
    case imagesOver = "images_over"
    case imageNotObject = "image_not_object"
    case imageNeedsAlt = "image_needs_alt"
    case imageCaption = "image_caption"
    case imageAt = "image_at"
    case imageSource = "image_source"
    case imageSvgText = "image_svg_text"
    case imageSrcText = "image_src_text"
    case srcNotDataURL = "src_not_data_url"
    case imageTypeNotAccepted = "image_type_not_accepted"
    case srcNotBase64 = "src_not_base64"
    case srcBadBase64 = "src_bad_base64"
    case imageTooBig = "image_too_big"
    case imageNotReal = "image_not_real"
    case svgNoElement = "svg_no_element"
    case svgUnsafe = "svg_unsafe"

    var severity: ImportReport.Issue.Severity {
        switch self {
        case .missingUsedField, .twinOfIgnored, .termUndefined, .matrixCatchAll, .matrixMultiAsk: .warning
        default: .error
        }
    }
}

/// A rule broken at a place below the value a check was given, with that rule's sentence.
struct ImportFinding: Error {
    let rule: FormatRule
    let message: String
    /// The steps down to the place: field names the check itself names and places in lists, so none needs escaping in a JSON pointer.
    let at: [String]

    init(_ rule: FormatRule, _ message: String, at: [String] = []) {
        self.rule = rule
        self.message = message
        self.at = at
    }

    /// The finding below `steps`, with `prefix` before its sentence: an image's name, or a question's tag.
    func below(_ steps: [String], prefix: String = "") -> ImportFinding {
        ImportFinding(rule, prefix + message, at: steps + at)
    }

    /// The issue this finding is, at its place in the file.
    func issue(about question: ImportReport.Issue.Question? = nil) -> ImportReport.Issue {
        ImportReport.Issue(severity: rule.severity, code: rule.rawValue, question: question, path: at.map { "/\($0)" }.joined(), message: message)
    }
}
