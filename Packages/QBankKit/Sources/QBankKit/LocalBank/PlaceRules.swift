import Foundation

/// The course the person used last, which the app opens on: `GET` and `PUT /api/me/place`.
enum PlaceRules {
    static func register(in router: inout BankRouter) {
        router.get("/api/me/place", read)
        router.put("/api/me/place", save)
    }

    /// The course used last, or null when it is archived or deleted, so the person lands on Home instead.
    private static func read(_ call: BankCall) throws -> BankAnswer {
        let course = try call.tx.rows(
            "SELECT c.id AS id FROM study_place p JOIN course c ON c.id = p.course_id WHERE c.archived_at IS NULL AND c.deleted_at IS NULL"
        ).first
        return .ok(.object(["courseId": .optional(course?.text("id"))]))
    }

    private static func save(_ call: BankCall) throws -> BankAnswer {
        let courseID = try BankBody(call.body).uuid("courseId")
        let course = try StudyLookup.course(call.tx, courseID)
        if course.archivedAt != nil { throw BankRefusal.courseNotFound }
        try remember(call.tx, courseID: course.id, at: call.nowText)
        return .ok(.object(["courseId": .string(course.id)]))
    }

    /// Remembers the course: opening it and answering in it both do.
    static func remember(_ tx: StoreTransaction, courseID: String, at time: String) throws {
        try tx.execute("DELETE FROM study_place")
        try tx.execute("INSERT INTO study_place (course_id, updated_at) VALUES (?, ?)", [.text(courseID), .text(time)])
    }
}
