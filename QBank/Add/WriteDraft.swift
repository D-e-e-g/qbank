import Foundation
import Observation

/// One question she is writing by hand: its text, its choices, which one is right, and an optional
/// explanation. Single answer has two to six choices she words; true or false always has the two.
nonisolated struct QuestionDraft: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case single
        case trueFalse

        var label: String {
            switch self {
            case .single: "Single answer"
            case .trueFalse: "True or false"
            }
        }
    }

    struct Choice: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var text = ""
    }

    static let trueFalseChoices = ["True", "False"]
    static let choiceRange = 2...6

    var id = UUID()
    var kind: Kind = .single
    /// The question itself, what the file calls `ask`.
    var ask = ""
    var choices: [Choice] = [Choice(), Choice(), Choice(), Choice()]
    /// The right choice of a single-answer question, by position. Nil until she marks one.
    var rightChoice: Int?
    /// The right answer of a true-or-false question: 0 for True, 1 for False. Nil until she marks one.
    var rightTrueFalse: Int?
    var explanation = ""

    /// The choices as she sees them: her own, or True and False.
    var choiceTexts: [String] {
        kind == .single ? choices.map(\.text) : Self.trueFalseChoices
    }

    /// The marked choice of the kind she is writing.
    var right: Int? {
        get { kind == .single ? rightChoice : rightTrueFalse }
        set {
            if kind == .single { rightChoice = newValue } else { rightTrueFalse = newValue }
        }
    }

    var canAddChoice: Bool {
        kind == .single && choices.count < Self.choiceRange.upperBound
    }

    var canRemoveChoice: Bool {
        kind == .single && choices.count > Self.choiceRange.lowerBound
    }

    var isBlank: Bool {
        [ask, explanation].allSatisfy(Self.isEmpty) && choices.allSatisfy { Self.isEmpty($0.text) }
    }

    /// The choices that go into the file, with their positions: her filled ones and the marked
    /// one, so the blank rows she left unused are dropped. True or false always has its two.
    var fileChoices: [(position: Int, text: String)] {
        choiceTexts.enumerated()
            .filter { kind == .trueFalse || !Self.isEmpty($0.element) || $0.offset == right }
            .map { ($0.offset, $0.element.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// What keeps the question from being saved, in her words: what the import check refuses in a
    /// question she wrote. Empty when it is ready.
    var problems: [String] {
        var found: [String] = []
        if Self.isEmpty(ask) { found.append("write the question") }
        if kind == .single {
            if choices.filter({ !Self.isEmpty($0.text) }).count < Self.choiceRange.lowerBound { found.append("write at least two choices") }
            if let right, choices.indices.contains(right), Self.isEmpty(choices[right].text) { found.append("the right choice is empty") }
        }
        if right == nil { found.append("mark the right answer") }
        return found
    }

    private static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func addChoice() {
        guard canAddChoice else { return }
        choices.append(Choice())
    }

    /// Removes a choice. The mark follows the choice it was on, and goes with it.
    mutating func removeChoice(at index: Int) {
        guard canRemoveChoice, choices.indices.contains(index) else { return }
        choices.remove(at: index)
        guard let marked = rightChoice else { return }
        if marked == index {
            rightChoice = nil
        } else if marked > index {
            rightChoice = marked - 1
        }
    }
}

/// A set she is writing: its name and its questions. It is kept on this phone until it is saved.
nonisolated struct SetDraft: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = ""
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
                id: "W\(index + 1)",
                ask: question.ask.trimmingCharacters(in: .whitespacesAndNewlines),
                options: question.fileChoices.map { position, text in
                    File.Option(t: text, ok: question.right == position ? true : nil)
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
            let type = "single"
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
