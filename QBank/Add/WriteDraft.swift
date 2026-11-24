import Foundation
import Observation

/// One question she is writing by hand: its text, its choices, which one is right (or which ones, for
/// select all that apply), and an optional explanation. Single answer and select all have two to six
/// choices she words; true or false always has the two.
nonisolated struct QuestionDraft: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case single
        case selectAll
        case trueFalse

        var label: String {
            switch self {
            case .single: "Single answer"
            case .selectAll: "Select all"
            case .trueFalse: "True or false"
            }
        }

        /// The type the question file names.
        var fileType: String { self == .selectAll ? "sata" : "single" }
    }

    struct Choice: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var text = ""
    }

    static let trueFalseChoices = ["True", "False"]
    static let choiceRange = 2...6

    var id = UUID()
    /// The id the question has in the question file. It stays with the question for as long as it
    /// is kept, through every edit of its set, so the answers given to it stay with it. Nil in a
    /// draft kept before ids were kept: the file then numbers it by its place.
    var fileID: String? = Self.newFileID()
    var kind: Kind = .single
    /// The question itself, what the file calls `ask`.
    var ask = ""
    var choices: [Choice] = [Choice(), Choice(), Choice(), Choice()]
    /// The right choice of a single-answer question, by position. Nil until she marks one.
    var rightChoice: Int?
    /// The right answer of a true-or-false question: 0 for True, 1 for False. Nil until she marks one.
    var rightTrueFalse: Int?
    /// The right choices of a select-all question, by position. At least one must be marked.
    var rightChoices: Set<Int> = []
    var explanation = ""

    static func newFileID() -> String {
        "W" + UUID().uuidString.prefix(8).lowercased()
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fileID = try values.decodeIfPresent(String.self, forKey: .fileID)
        kind = try values.decode(Kind.self, forKey: .kind)
        ask = try values.decode(String.self, forKey: .ask)
        choices = try values.decode([Choice].self, forKey: .choices)
        rightChoice = try values.decodeIfPresent(Int.self, forKey: .rightChoice)
        rightTrueFalse = try values.decodeIfPresent(Int.self, forKey: .rightTrueFalse)
        rightChoices = try values.decodeIfPresent(Set<Int>.self, forKey: .rightChoices) ?? []
        explanation = try values.decode(String.self, forKey: .explanation)
    }

    /// The choices as she sees them: her own, or True and False.
    var choiceTexts: [String] {
        kind == .trueFalse ? Self.trueFalseChoices : choices.map(\.text)
    }

    /// The positions marked right: one, or any number for select all.
    var rightPositions: Set<Int> {
        switch kind {
        case .single: rightChoice.map { [$0] } ?? []
        case .selectAll: rightChoices
        case .trueFalse: rightTrueFalse.map { [$0] } ?? []
        }
    }

    /// Marks a choice. Single answer and true or false keep one right choice; select all toggles it.
    mutating func mark(_ position: Int) {
        switch kind {
        case .single: rightChoice = position
        case .selectAll:
            if !rightChoices.insert(position).inserted { rightChoices.remove(position) }
        case .trueFalse: rightTrueFalse = position
        }
    }

    var canAddChoice: Bool {
        kind != .trueFalse && choices.count < Self.choiceRange.upperBound
    }

    var canRemoveChoice: Bool {
        kind != .trueFalse && choices.count > Self.choiceRange.lowerBound
    }

    var isBlank: Bool {
        [ask, explanation].allSatisfy(Self.isEmpty) && choices.allSatisfy { Self.isEmpty($0.text) }
    }

    /// The choices that go into the file, with their positions: her filled ones and the marked
    /// one, so the blank rows she left unused are dropped. True or false always has its two.
    var fileChoices: [(position: Int, text: String)] {
        choiceTexts.enumerated()
            .filter { kind == .trueFalse || !Self.isEmpty($0.element) || rightPositions.contains($0.offset) }
            .map { ($0.offset, $0.element.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// What keeps the question from being saved, in her words: what the import check refuses in a
    /// question she wrote. Empty when it is ready.
    var problems: [String] {
        var found: [String] = []
        if Self.isEmpty(ask) { found.append("write the question") }
        if kind != .trueFalse {
            if choices.filter({ !Self.isEmpty($0.text) }).count < Self.choiceRange.lowerBound { found.append("write at least two choices") }
            if rightPositions.contains(where: { choices.indices.contains($0) && Self.isEmpty(choices[$0].text) }) {
                found.append(kind == .selectAll ? "a right choice is empty" : "the right choice is empty")
            }
        }
        if rightPositions.isEmpty { found.append(kind == .selectAll ? "mark at least one right answer" : "mark the right answer") }
        return found
    }

    private static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func addChoice() {
        guard canAddChoice else { return }
        choices.append(Choice())
    }

    /// Removes a choice. The marks follow the choices they were on, and the removed one's goes with it.
    mutating func removeChoice(at index: Int) {
        guard canRemoveChoice, choices.indices.contains(index) else { return }
        choices.remove(at: index)
        func moved(_ marked: Int) -> Int? { marked == index ? nil : marked > index ? marked - 1 : marked }
        rightChoice = rightChoice.flatMap(moved)
        rightChoices = Set(rightChoices.compactMap(moved))
    }
}

/// The saved set a draft edits: where it is, so saving files the new version in its place, and
/// which version of it she opened, so a set replaced or restored since is not overwritten unasked.
nonisolated struct EditedSet: Codable, Equatable, Sendable {
    let setID: String
    let courseID: String
    let folderID: String
    /// When the version she is editing became the set's current one: the set row's `activeSince`.
    var activeSince: Date
}

/// A set she is writing: its name and its questions. It is kept on this phone until it is saved.
/// A draft that edits a saved set carries it in `editing`: saving then saves a new version of that set.
nonisolated struct SetDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = ""
    var editing: EditedSet?
    var questions: [QuestionDraft] = [QuestionDraft()]
    var updatedAt = Date()

    /// Nothing written yet, so there is nothing to keep.
    var isBlank: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && questions.allSatisfy(\.isBlank)
    }

    /// The question file this draft is: the same JSON a pasted or chosen file holds, so the import
    /// check judges it with the rules it applies to every file.
    func file() -> String {
        let items = questions.enumerated().map { index, question in
            File.Question(
                id: question.fileID ?? "W\(index + 1)",
                type: question.kind.fileType,
                ask: question.ask.trimmingCharacters(in: .whitespacesAndNewlines),
                options: question.fileChoices.map { position, text in
                    File.Option(t: text, ok: question.rightPositions.contains(position) ? true : nil)
                },
                rationale: Self.nonEmpty(question.explanation)
            )
        }
        let file = File(title: title.trimmingCharacters(in: .whitespacesAndNewlines), questions: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(file) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The question file's shape, in the names the importer reads.
    private struct File: Encodable {
        struct Option: Encodable {
            let t: String
            let ok: Bool?
        }

        struct Question: Encodable {
            let id: String
            let type: String
            let ask: String
            let options: [Option]
            let rationale: String?
        }

        let title: String
        let questions: [Question]
    }
}

/// The sets she has begun and not saved, kept on this phone like the Look and the lock: never sent
/// anywhere. Each account has its own: another account signed in on this phone never sees them, a
/// sign-out keeps them for when she signs back in, and deleting the account deletes them.
@Observable
final class WriteDraftStore {
    /// Where the drafts of the account with this id are kept.
    static func key(for accountID: String) -> String {
        "qbank-write-drafts.\(accountID)"
    }

    /// The drafts of the account signed in, the one she touched last first. None when no one is.
    private(set) var drafts: [SetDraft] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accountID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Shows the drafts of the account signed in, or none when no one is.
    func open(accountID: String?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        let stored = accountID.flatMap { defaults.data(forKey: Self.key(for: $0)) }.flatMap { try? JSONDecoder().decode([SetDraft].self, from: $0) } ?? []
        drafts = stored.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Deletes every draft of the account with this id, for an account that is gone.
    func erase(accountID: String) {
        defaults.removeObject(forKey: Self.key(for: accountID))
        if accountID == self.accountID { drafts = [] }
    }

    func draft(id: UUID) -> SetDraft? {
        drafts.first { $0.id == id }
    }

    /// Keeps `draft`, or forgets it when it is blank, so opening the editor and leaving leaves nothing.
    func keep(_ draft: SetDraft) {
        var next = drafts.filter { $0.id != draft.id }
        if !draft.isBlank {
            var kept = draft
            kept.updatedAt = Date()
            next.insert(kept, at: 0)
        }
        replace(with: next)
    }

    func discard(id: UUID) {
        replace(with: drafts.filter { $0.id != id })
    }

    private func replace(with next: [SetDraft]) {
        guard let accountID, next != drafts else { return }
        drafts = next
        if next.isEmpty {
            defaults.removeObject(forKey: Self.key(for: accountID))
        } else if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key(for: accountID))
        }
    }
}
