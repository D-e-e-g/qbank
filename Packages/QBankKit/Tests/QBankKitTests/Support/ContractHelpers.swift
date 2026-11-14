import Foundation
@testable import QBankKit

// Shared by the contract suites. Each contract test drives the client through one recorded
// exchange with the real server routes and checks both directions: the request the client builds
// matches the recorded one, and the recorded response decodes into the models.

/// The course id in a recorded `/api/courses/{id}/...` path.
func courseID(of fixture: Fixture) -> String {
    let parts = fixture.request.path.split(separator: "/")
    return String(parts[2])
}

/// The folder ids a recorded request sent.
func folderIDs(of fixture: Fixture) -> [String] {
    fixture.request.body?["folderIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
}

extension SavedAttempt {
    /// What the server answers to a repeated id: the saved attempt with `replayed` set.
    static func replayOf(_ saved: SavedAttempt) -> SavedAttempt {
        SavedAttempt(
            clientAttemptID: saved.clientAttemptID, questionID: saved.questionID, courseID: saved.courseID,
            status: saved.status, points: saved.points, maxPoints: saved.maxPoints, guessed: saved.guessed,
            answeredAt: saved.answeredAt, inReview: saved.inReview, label: saved.label, pointsText: saved.pointsText,
            ruleText: saved.ruleText, replayed: true
        )
    }
}
