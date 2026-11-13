import Foundation
import QBankKit
import Testing
@testable import QBank

/// The Debug fake server's own routes, called as raw requests: the admin's read-only view, the
/// account gates, editing the catalog, imports, a course's delete, and an answer it cannot read.
/// Each says what the fake answers and in which words, so a change to how it is built cannot
/// change what the app and the UI tests see.
struct FakeServerRoutesTests {
    /// One answer of the fake server: its status, its JSON, and its response.
    struct Answer {
        let status: Int
        let body: [String: Any]
        let data: Data
        let response: HTTPURLResponse

        var message: String? { body["message"] as? String }
        var error: String? { body["error"] as? String }
        subscript(key: String) -> Any? { body[key] }
    }

    /// Raw calls to one fake server, with a session's bearer token or none.
    struct Calls {
        let server: FakeQBankServer
        var token: String? = FakeQBankServer.sessionToken

        init(_ server: FakeQBankServer = FakeQBankServer(signedIn: true)) {
            self.server = server
        }

        func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, query: String? = nil, raw: Data? = nil) async throws -> Answer {
            var request = URLRequest(url: URL(string: "https://fake-qbank.invalid\(path)\(query.map { "?\($0)" } ?? "")")!)
            request.httpMethod = method
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            if let raw { request.httpBody = raw }
            let (data, response) = try await server.send(request)
            let json = data.isEmpty ? [:] : try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return Answer(status: response.statusCode, body: json, data: data, response: response)
        }

        func catalog() async throws -> (semesters: [[String: Any]], topics: [[String: Any]]) {
            let answer = try await call("GET", "/api/semesters")
            return (answer["semesters"] as? [[String: Any]] ?? [], answer["topics"] as? [[String: Any]] ?? [])
        }

        func course(_ id: String) async throws -> [String: Any]? {
            try await catalog().semesters.flatMap { $0["courses"] as? [[String: Any]] ?? [] }.first { $0["id"] as? String == id }
        }
    }

    static let mentalHealth = FakeQBankServer.mentalHealthID
    static let fundamentals = FakeQBankServer.fundamentalsID

    // MARK: Accounts and the admin

    @Test func everyCallButSignInAndSignUpNeedsASession() async throws {
        var calls = Calls(FakeQBankServer(signedIn: false))
        calls.token = nil
        let none = try await calls.call("GET", "/api/semesters")
        #expect(none.status == 401)
        #expect(none.error == "unauthenticated")
        #expect(none.message == "Sign in to continue.")
        calls.token = "not-a-session"
        #expect(try await calls.call("GET", "/api/session").status == 401)
    }

    @Test func aTemporaryPasswordAllowsOnlyTheAccountRoutes() async throws {
        var calls = Calls(FakeQBankServer(signedIn: false))
        let reset = FakeQBankServer.resetStudent
        let signedIn = try await calls.call("POST", "/api/sign-in/password", ["email": reset.email.uppercased(), "password": reset.password])
        #expect(signedIn.status == 200)
        calls.token = try #require(signedIn["token"] as? String)
        let session = try await calls.call("GET", "/api/session")
        #expect((session["user"] as? [String: Any])?["mustChangePassword"] as? Bool == true)
        let refused = try await calls.call("GET", "/api/semesters")
        #expect(refused.status == 403)
        #expect(refused.error == "must_change_password")
        #expect(refused.message == "Choose a new password to continue.")
        let delete = try await calls.call("DELETE", "/api/me", ["password": reset.password])
        #expect(delete.status == 403)
        #expect(delete.error == "must_change_password")
    }

    @Test func theFifthWrongPasswordLocksDeletingTheAccountAndSaysForHowLong() async throws {
        let calls = Calls()
        for _ in 1...4 {
            let wrong = try await calls.call("DELETE", "/api/me", ["password": "not-it"])
            #expect(wrong.status == 401)
            #expect(wrong.message == "That password is not right.")
        }
        for password in ["not-it", FakeQBankServer.student.password] {
            let locked = try await calls.call("DELETE", "/api/me", ["password": password])
            #expect(locked.status == 429)
            #expect(locked.error == "too_many_attempts")
            #expect(locked.message == "Too many tries. Try again in 15 minutes.")
            #expect(locked["retryAfterSeconds"] as? Int == 900)
            #expect(locked.response.value(forHTTPHeaderField: "Retry-After") == "900")
        }
        #expect(try await calls.call("DELETE", "/api/me", ["password": ""]).status == 400)
    }

    @Test func thePaletteTakesOnlyItsNamesAndGoesWithTheAccount() async throws {
        let calls = Calls()
        let slate = try await calls.call("PUT", "/api/me/palette", ["palette": "slate"])
        #expect(slate.status == 200)
        #expect(slate["palette"] as? String == "slate")
        #expect(slate["email"] as? String == FakeQBankServer.student.email)
        let unknown = try await calls.call("PUT", "/api/me/palette", ["palette": "pink"])
        #expect(unknown.status == 400)
        #expect(unknown.error == "invalid_request")
        #expect(try await calls.call("PUT", "/api/me/palette", [:]).status == 400)
        let session = try await calls.call("GET", "/api/session")
        #expect((session["user"] as? [String: Any])?["palette"] as? String == "slate")
    }

    @Test func theAdminReadsHerAccountAndIsRefusedEveryWriteInTheServersWords() async throws {
        let calls = Calls(FakeQBankServer(signedIn: true, as: FakeQBankServer.owner))
        let students = try await calls.call("GET", "/api/admin/students")
        #expect(students.status == 200)
        #expect(students["viewingId"] as? String == "fake-student")
        #expect((students["students"] as? [[String: Any]])?.map { $0["email"] as? String } == [FakeQBankServer.viewedEmail, FakeQBankServer.maker.email])
        let maker = try await calls.call("GET", "/api/question-maker")
        #expect(maker.status == 200)
        #expect(maker["available"] as? Bool == false)
        #expect(maker["reason"] as? String == "This is a read-only view of a user account. Nothing here can be changed.")
        #expect(try await calls.call("GET", "/api/semesters").status == 200)
        #expect(try await calls.call("PUT", "/api/me/palette", ["palette": "slate"]).status == 200)
        #expect(try await calls.call("POST", "/api/imports/check", ["source": "[]"]).status == 200)

        let answer = try await calls.call("POST", "/api/attempts", ["clientAttemptId": "a1"])
        #expect(answer.status == 403)
        #expect(answer.error == "admin_cannot_record_answer")
        #expect(answer.message == "The admin cannot record an answer as her.")
        for (method, path) in [("DELETE", "/api/exams/e1"), ("POST", "/api/exams/e1/undo-delete")] {
            let exam = try await calls.call(method, path)
            #expect(exam.status == 403)
            #expect(exam.error == "admin_cannot_delete_exam")
            #expect(exam.message == "Only the user account can delete her exams or bring them back.")
        }
        for (method, path) in [("POST", "/api/topics"), ("PATCH", "/api/courses/\(Self.mentalHealth)"), ("POST", "/api/exams/e1/finish")] {
            let write = try await calls.call(method, path, ["title": "Pharmacology"])
            #expect(write.status == 403)
            #expect(write.error == "admin_read_only")
            #expect(write.message == "This is a read-only view of a user account. Nothing here can be changed.")
        }
    }

    // MARK: Editing the catalog

    @Test func semestersAndCoursesAreRefusedInTheServersWords() async throws {
        let calls = Calls()
        let semester1 = "/api/semesters/\(FakeQBankServer.semester1ID)"
        let refusals: [(String, String, [String: Any], Int, String)] = [
            ("POST", "/api/semesters", ["number": 4], 400, "A semester is 1, 2, or 3."),
            ("POST", "/api/semesters", ["number": 1], 409, "Semester 1 already exists."),
            ("PATCH", "/api/semesters/nope", ["name": "Fall"], 404, "That semester is not in the app."),
            ("PATCH", semester1, ["name": "  "], 400, "Semester name is required."),
            ("PATCH", semester1, ["name": String(repeating: "a", count: 81)], 400, "Semester name is too long."),
            ("PATCH", semester1, ["startsOn": "Sept 1"], 400, "Start date has to be a date like 2026-09-01."),
            ("PATCH", semester1, ["endsOn": "2026-9-1"], 400, "End date has to be a date like 2026-09-01."),
            ("POST", "/api/courses", ["semesterId": "nope", "code": "NURS 1", "title": "One"], 404, "That semester is not in the app."),
            ("POST", "/api/courses", ["semesterId": FakeQBankServer.semester1ID, "code": " ", "title": "One"], 400, "Course code is required."),
            ("POST", "/api/courses", ["semesterId": FakeQBankServer.semester1ID, "code": "NURS 1", "title": String(repeating: "a", count: 161)], 400, "Course name is too long."),
            ("POST", "/api/courses", ["semesterId": FakeQBankServer.semester1ID, "code": "nurs 220", "title": "Again"], 409, "This semester already has a course with the code nurs 220."),
            ("PATCH", "/api/courses/nope", ["title": "Gone"], 404, "That course is not in the app."),
            ("PATCH", "/api/courses/\(Self.mentalHealth)", ["code": "NURS 220"], 409, "This semester already has a course with the code NURS 220."),
            ("PATCH", "/api/courses/\(Self.mentalHealth)", ["semesterId": "nope"], 404, "That semester is not in the app."),
        ]
        for (method, path, body, status, message) in refusals {
            let refused = try await calls.call(method, path, body)
            #expect(refused.status == status, "\(method) \(path) \(body)")
            #expect(refused.error == "request_refused")
            #expect(refused.message == message)
        }

        let edited = try await calls.call("PATCH", semester1, ["name": " Fall ", "startsOn": "2026-09-01", "endsOn": "2026-12-18"])
        #expect(edited.status == 200)
        #expect(edited["name"] as? String == "Fall")
        #expect(edited["startsOn"] as? String == "2026-09-01")
        #expect(edited["endsOn"] as? String == "2026-12-18")
        let cleared = try await calls.call("PATCH", semester1, ["endsOn": ""])
        #expect(cleared["endsOn"] is NSNull)
        let archived = try await calls.call("PATCH", semester1, ["archived": true])
        #expect(archived["archivedAt"] is String)
        #expect(try await calls.call("PATCH", semester1, ["archived": false])["archivedAt"] is NSNull)

        let added = try await calls.call("POST", "/api/courses", ["semesterId": FakeQBankServer.semester2ID, "code": " NURS 330 ", "title": "Pediatrics"])
        #expect(added.status == 201)
        #expect(added["code"] as? String == "NURS 330")
        #expect(added["kind"] as? String == "course")
        #expect(added["questionCount"] as? Int == 0)
        #expect(added["sortOrder"] as? Int == 1)
        let id = try #require(added["id"] as? String)
        let detail = try await calls.call("GET", "/api/courses/\(id)")
        #expect(detail.status == 200)
        #expect(detail["questionCount"] as? Int == 0)
        #expect((detail["semester"] as? [String: Any])?["number"] as? Int == 2)
        #expect(try await calls.call("GET", "/api/courses/nope").message == "That course is not in the app.")
    }

    @Test func topicsTakeANameAndArchivingOnlyAndKeepHerOrder() async throws {
        let calls = Calls()
        let pharmacology = try await calls.call("POST", "/api/topics", ["title": " Pharmacology "])
        #expect(pharmacology.status == 201)
        #expect(pharmacology["kind"] as? String == "topic")
        #expect(pharmacology["title"] as? String == "Pharmacology")
        #expect(pharmacology["code"] as? String == "")
        let first = try #require(pharmacology["id"] as? String)
        let anatomy = try await calls.call("POST", "/api/topics", ["title": "Anatomy"])
        let second = try #require(anatomy["id"] as? String)
        #expect(anatomy["sortOrder"] as? Int == 2)

        let refusals: [(String, String, [String: Any], Int, String)] = [
            ("POST", "/api/topics", ["title": "pharmacology"], 409, "You already have a topic named pharmacology."),
            ("POST", "/api/topics", ["title": ""], 400, "Topic name is required."),
            ("PATCH", "/api/courses/\(first)", ["code": "X"], 400, "A topic has no code or semester."),
            ("PATCH", "/api/courses/\(first)", ["semesterId": FakeQBankServer.semester1ID], 400, "A topic has no code or semester."),
            ("PATCH", "/api/courses/\(first)", ["title": "anatomy"], 409, "You already have a topic named anatomy."),
            ("PUT", "/api/topic-order", ["topicIds": [first]], 409, "Your topics changed. Reload and try again."),
            ("PUT", "/api/topic-order", ["topicIds": [first, first]], 409, "Your topics changed. Reload and try again."),
            ("PUT", "/api/topic-order", [:], 409, "Your topics changed. Reload and try again."),
        ]
        for (method, path, body, status, message) in refusals {
            let refused = try await calls.call(method, path, body)
            #expect(refused.status == status, "\(method) \(path) \(body)")
            #expect(refused.message == message)
        }

        let ordered = try await calls.call("PUT", "/api/topic-order", ["topicIds": [second, first]])
        #expect(ordered.status == 200)
        #expect((ordered["topics"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Anatomy", "Pharmacology"])
        #expect(try await calls.catalog().topics.map { $0["id"] as? String } == [second, first])
        let renamed = try await calls.call("PATCH", "/api/courses/\(first)", ["title": "Pharmacology II", "archived": true])
        #expect(renamed["title"] as? String == "Pharmacology II")
        #expect(renamed["archivedAt"] is String)
    }

    // MARK: Imports

    static func file(_ title: String = "Invented Set", kind: String? = nil) -> String {
        let kindField = kind.map { #""kind":"\#($0)","# } ?? ""
        return #"{\#(kindField)"title":"\#(title)","questions":[{"id":"Q1","type":"sata","stem":"Stem.","ask":"Which apply?","options":[{"t":"A","ok":true},{"t":"B"},{"t":"C"}],"rationale":"Because.","takeaway":"Remember."}]}"#
    }

    @Test func anImportIsRefusedInTheServersWordsAndWritesNothing() async throws {
        let calls = Calls()
        let before = try await calls.catalog()
        let source = Self.file()
        let newCourse: [String: Any] = ["code": "NURS 400", "title": "Leadership", "semesterNumber": 3]
        let refusals: [([String: Any], Int, String)] = [
            (["source": source, "title": "  ", "courseId": Self.mentalHealth], 400, "Set name is required."),
            (["source": source, "courseId": Self.mentalHealth, "newCourse": newCourse], 400, "Choose a course, a new course or a new topic, not more than one."),
            (["source": source], 400, "Choose a course."),
            (["source": source, "courseId": Self.mentalHealth, "folderId": FakeStudy.week1, "folderName": "Week 1"], 400, "Choose a folder or a folder name, not both."),
            (["source": source, "newTopic": ["title": "Pharmacology"], "folderId": FakeStudy.week1], 400, "A new course has no folders yet. Name a folder, or leave it for Unsorted."),
            (["source": source, "courseId": Self.mentalHealth, "weekLabel": " "], 400, "Folder name is required."),
            (["source": source, "courseId": "nope"], 404, "That course is not in the app."),
            (["source": source, "courseId": Self.mentalHealth, "folderId": "nope"], 400, "That folder is not in this course."),
            (["source": source, "newCourse": newCourse.merging(["semesterNumber": 4]) { $1 }], 400, "A semester is 1, 2, or 3."),
            (["source": source, "newCourse": newCourse.merging(["title": ""]) { $1 }], 400, "Course name is required."),
            (["source": source, "newCourse": newCourse.merging(["code": "nurs 310", "semesterNumber": 1]) { $1 }], 409, "This semester already has a course with the code nurs 310."),
            (["source": source, "newTopic": ["title": ""]], 400, "Topic name is required."),
        ]
        for (body, status, message) in refusals {
            let refused = try await calls.call("POST", "/api/imports", body)
            #expect(refused.status == status, "\(body)")
            #expect(refused.error == "request_refused")
            #expect(refused.message == message)
        }
        let invalid = try await calls.call("POST", "/api/imports", ["source": "not json", "courseId": Self.mentalHealth])
        #expect(invalid.status == 400)
        #expect(invalid.error == "invalid_import")
        #expect(invalid.message == "This is not valid JSON. Ask your AI chat to resend only the JSON block.")
        #expect(invalid["errors"] as? [String] == ["This is not valid JSON. Ask your AI chat to resend only the JSON block."])
        #expect(invalid["warnings"] as? [String] == [])

        let after = try await calls.catalog()
        #expect(after.semesters.count == before.semesters.count)
        #expect(after.topics.isEmpty)
        #expect(try await calls.course(Self.mentalHealth)?["questionCount"] as? Int == 86)
    }

    @Test func aSetOfTheSameNameAsksFirstThenReplacesAndRestoreBringsTheOldOneBack() async throws {
        let calls = Calls()
        let imported = try await calls.call("POST", "/api/imports", ["source": Self.file(), "courseId": Self.mentalHealth, "folderId": FakeStudy.week1])
        #expect(imported.status == 201)
        #expect(imported["kind"] as? String == "imported")
        #expect(imported["setKind"] as? String == "practice")
        #expect(imported["courseCode"] as? String == "NURS 310")
        #expect(imported["folderId"] as? String == FakeStudy.week1)
        #expect(imported["questionCount"] as? Int == 1)
        #expect(imported["title"] as? String == "Invented Set")
        let original = try #require(imported["setId"] as? String)
        #expect(try await calls.course(Self.mentalHealth)?["questionCount"] as? Int == 87)

        let again: [String: Any] = ["source": Self.file(), "courseId": Self.mentalHealth, "title": "invented set"]
        let conflict = try await calls.call("POST", "/api/imports", again)
        #expect(conflict.status == 409)
        #expect(conflict["conflict"] as? Bool == true)
        #expect(conflict["setId"] as? String == original)
        #expect(conflict["folderId"] as? String == FakeStudy.week1)
        #expect(conflict["existingQuestionCount"] as? Int == 1)
        #expect(conflict["incomingQuestionCount"] as? Int == 1)
        #expect(conflict["title"] as? String == "invented set")

        let replaced = try await calls.call("POST", "/api/imports", again.merging(["decision": "replace"]) { $1 })
        #expect(replaced.status == 201)
        #expect(replaced["kind"] as? String == "replaced")
        #expect(replaced["folderId"] as? String == FakeStudy.week1)
        let replacement = try #require(replaced["setId"] as? String)
        #expect(replacement != original)
        #expect(try await calls.course(Self.mentalHealth)?["questionCount"] as? Int == 87, "only the current version counts")
        let set = try await calls.call("GET", "/api/practice-sets/\(replacement)")
        #expect(set["title"] as? String == "invented set")
        #expect(set["folderId"] as? String == FakeStudy.week1)

        let restored = try await calls.call("POST", "/api/practice-sets/\(replacement)/restore")
        #expect(restored.status == 200)
        #expect(restored["id"] as? String == original)
        #expect(restored["title"] as? String == "Invented Set")
        let twice = try await calls.call("POST", "/api/practice-sets/\(replacement)/restore")
        #expect(twice.status == 404)
        #expect(twice.message == "That set is not the current version.")
    }

    @Test func anImportMakesItsCourseWithItsSemesterOrItsTopic() async throws {
        let calls = Calls()
        let course = try await calls.call("POST", "/api/imports", [
            "source": Self.file(), "newCourse": ["code": "NURS 400", "title": "Leadership", "semesterNumber": 3],
        ])
        #expect(course.status == 201)
        #expect(course["courseCode"] as? String == "NURS 400")
        #expect(course["folderName"] as? String == "Unsorted")
        let courseID = try #require(course["courseId"] as? String)
        let semesters = try await calls.catalog().semesters
        #expect(semesters.map { $0["number"] as? Int } == [1, 2, 3])
        #expect((semesters.last?["courses"] as? [[String: Any]])?.map { $0["questionCount"] as? Int } == [1])
        let detail = try await calls.call("GET", "/api/courses/\(courseID)")
        #expect(detail["questionCount"] as? Int == 1)
        #expect(detail["examQuestionCount"] as? Int == 1)
        #expect(detail["code"] as? String == "NURS 400")
        #expect((detail["folders"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Unsorted"])

        let topic = try await calls.call("POST", "/api/imports", ["source": Self.file(), "newTopic": ["title": "Pharmacology"], "folderName": "Week 1"])
        #expect(topic.status == 201)
        #expect(topic["folderName"] as? String == "Week 1")
        #expect(try await calls.catalog().topics.map { $0["title"] as? String } == ["Pharmacology"])

        let exam = try await calls.call("POST", "/api/imports", ["source": Self.file("Invented Exam", kind: "exam"), "courseId": Self.fundamentals])
        #expect(exam.status == 201)
        #expect(exam["setKind"] as? String == "exam")
        #expect(exam.body.keys.contains("examPageId"))
        #expect(try await calls.course(Self.fundamentals)?["questionCount"] as? Int == 146, "an exam set adds no practice questions")
        let folders = try await calls.call("GET", "/api/courses/\(Self.fundamentals)")["folders"] as? [[String: Any]] ?? []
        #expect(folders.first { $0["name"] as? String == "Unsorted" }?["examBankCount"] as? Int == 1)
    }

    // MARK: A course's delete

    @Test func aCourseIsDeletedOnlyWithItsConfirmAndLeavesHerPlace() async throws {
        let calls = Calls()
        let course = "/api/courses/\(Self.fundamentals)"
        #expect(try await calls.call("GET", "/api/me/place")["courseId"] as? String == Self.mentalHealth)
        #expect(try await calls.call("PUT", "/api/me/place", ["courseId": Self.fundamentals])["courseId"] as? String == Self.fundamentals)

        let preview = try await calls.call("GET", "\(course)/delete-preview")
        #expect(preview.status == 200)
        #expect(preview["questionCount"] as? Int == 146)
        #expect(preview["undoDays"] as? Int == 30)
        #expect(preview["refusal"] is NSNull)
        let confirm = try #require(preview["confirm"] as? String)
        #expect(confirm.count == 16)
        let unconfirmed = try await calls.call("DELETE", course)
        #expect(unconfirmed.status == 409)
        #expect(unconfirmed.error == "confirmation_required")
        #expect(unconfirmed.message == "Look at what goes with NURS 220 and confirm it before deleting it.")
        let changed = try await calls.call("DELETE", course, query: "confirm=0000000000000000")
        #expect(changed.status == 409)
        #expect(changed.error == "deletion_changed")
        #expect(changed.message == "NURS 220 changed since you were warned. Look again before deleting it.")

        let deleted = try await calls.call("DELETE", course, query: "confirm=\(confirm)")
        #expect(deleted.status == 204)
        #expect(deleted.data.isEmpty)
        #expect(try await calls.call("GET", "/api/me/place")["courseId"] is NSNull)
        let gone = try await calls.call("GET", course)
        #expect(gone.status == 404)
        #expect(gone.error == "course_not_found")
        #expect(try await calls.call("GET", "\(course)/delete-preview").status == 404)
        let listed = try await calls.call("GET", "/api/deleted-courses")
        #expect((listed["courses"] as? [[String: Any]])?.map { $0["id"] as? String } == [Self.fundamentals])

        let back = try await calls.call("POST", "\(course)/undo-delete")
        #expect(back.status == 200)
        #expect(back["code"] as? String == "NURS 220")
        let again = try await calls.call("POST", "\(course)/undo-delete")
        #expect(again.status == 409)
        #expect(again.message == "NURS 220 is not deleted.")
        #expect(try await calls.call("POST", "/api/courses/nope/undo-delete").status == 404)
        #expect(try await calls.call("GET", "/api/me/place")["courseId"] as? String == Self.fundamentals)
    }

    // MARK: Practice

    @Test func anAnswerOrSetItCannotFindIsRefusedInTheServersWords() async throws {
        let calls = Calls()
        let unreadable = try await calls.call("POST", "/api/attempts", raw: Data("not json".utf8))
        #expect(unreadable.status == 400)
        #expect(unreadable.error == "invalid_request")
        #expect(unreadable.message == "That answer could not be read.")
        let unknown = try QBankJSON.encoder.encode(AttemptSubmission(questionID: "nope", response: .single(choice: 0)))
        let notThere = try await calls.call("POST", "/api/attempts", raw: unknown)
        #expect(notThere.status == 404)
        #expect(notThere.message == "That question is not in the app.")
        // The second question of a set is a priority question, which a single answer cannot score.
        let mismatched = try QBankJSON.encoder.encode(AttemptSubmission(questionID: "mixed-v1-q1", response: .single(choice: 0)))
        let unscored = try await calls.call("POST", "/api/attempts", raw: mismatched)
        #expect(unscored.status == 400)
        #expect(unscored.error == "invalid_request")
        #expect(unscored.message == "Cannot score a priority question with a single answer.")
        for (method, path) in [("GET", "/api/practice-sets/nope"), ("POST", "/api/practice-sets/nope/start-over")] {
            let missing = try await calls.call(method, path)
            #expect(missing.status == 404)
            #expect(missing.message == "That set is not in the app.")
        }
        let route = try await calls.call("GET", "/api/nowhere")
        #expect(route.status == 404)
        #expect(route.message == "That is not in the app.")
    }
}
