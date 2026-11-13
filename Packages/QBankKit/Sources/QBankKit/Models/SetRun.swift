import Foundation

/// Where she stands in a practice set: the server's `run`, sent on every set row and on the set
/// itself. It alone decides a row's words, whether the set opens where she left it or at question 1,
/// and whether answering starts a new run.
public enum SetRun: String, Codable, Sendable, CaseIterable {
    /// Nothing answered yet.
    case new
    /// A sitting to continue: the set opens at the first question she has not answered in it.
    case midway
    /// Answered before, but the set opens at question 1: she chose Start over, or answered it only
    /// on exams.
    case restarted
    /// Every current question has an answer, even with a retake under way. The set opens at
    /// question 1, and answering starts a new run.
    case done

    /// The run a row from a server or a saved copy from before `run` stands at, by the rule the
    /// app used then: every question answered is Done, a sitting is Midway, no answer is New.
    public init(answeredCount: Int, questionCount: Int, continues: Bool) {
        if questionCount > 0, answeredCount >= questionCount {
            self = .done
        } else if continues {
            self = .midway
        } else {
            self = answeredCount == 0 ? .new : .restarted
        }
    }

    /// Reads `run` when the server sent one this version knows, and nil otherwise.
    static func decodeIfPresent<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> SetRun? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return SetRun(rawValue: raw)
    }
}
