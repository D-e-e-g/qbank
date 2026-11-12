#if DEBUG
import Foundation

/// A set's latest sitting on the fake server: open, or closed when she finished it or chose Start over.
nonisolated struct FakeSitting: Codable {
    var isOpen = true
    var endedByStartOver = false
    /// The answers it opened with.
    let seeded: Set<String>
    /// The questions answered in it.
    var own: Set<String>
    let startedAt: Date

    /// Closes it once it has an answer to every question.
    mutating func closeIfFinished(answered: Set<String>, questionIDs: [String]) {
        if own.union(seeded.intersection(answered)).isSuperset(of: questionIDs) {
            isOpen = false
        }
    }
}

/// The rules of the server's `progress/sittings.ts`, for `FakeQBankServer`. Each takes the set's
/// questions in order, the ones she has an answer to, and the set's latest sitting.
nonisolated enum FakeSittingRules {
    /// Where she stands in the set, the `run` every row and the set itself send: New with nothing
    /// answered, Done once every question has an answer even with a retake open, Midway with a
    /// sitting to continue, and otherwise Restarted.
    static func run(answered: Set<String>, sitting: FakeSitting?, questionIDs: [String]) -> String {
        if answered.isEmpty { return "new" }
        if answered.count == questionIDs.count { return "done" }
        return continuing(answered: answered, sitting: sitting, questionIDs: questionIDs) == nil ? "restarted" : "midway"
    }

    /// The questions answered in the sitting she would continue, in the set's order, or nil when
    /// there is nothing to continue: once every question has an answer, even with a retake open.
    static func continuing(answered: Set<String>, sitting: FakeSitting?, questionIDs: [String]) -> [String]? {
        if answered.count == questionIDs.count { return nil }
        let inSitting: Set<String>
        if let sitting, sitting.isOpen {
            inSitting = sitting.own.union(sitting.seeded.intersection(answered))
        } else if sitting?.endedByStartOver == true {
            inSitting = []
        } else {
            inSitting = answered
        }
        let shown = questionIDs.filter(inSitting.contains)
        return shown.isEmpty || shown.count == questionIDs.count ? nil : shown
    }

    /// The set's sitting once an answer joins it, opening one if it should, or nil when the answer
    /// joins none. `answered` is what she had before the answer, so the seed leaves it out.
    static func joining(
        _ questionID: String, answered: Set<String>, sitting: FakeSitting?, questionIDs: [String], fromReview: Bool, at date: Date
    ) -> FakeSitting? {
        if var sitting, sitting.isOpen {
            sitting.own.insert(questionID)
            sitting.closeIfFinished(answered: answered, questionIDs: questionIDs)
            return sitting
        }
        guard !fromReview else { return nil }
        let beginsAgain = answered.count == questionIDs.count || sitting?.endedByStartOver == true
        if beginsAgain, questionIDs.first != questionID { return nil }
        var opened = FakeSitting(seeded: beginsAgain ? [] : answered, own: [questionID], startedAt: date)
        opened.closeIfFinished(answered: answered, questionIDs: questionIDs)
        return opened
    }
}
#endif
