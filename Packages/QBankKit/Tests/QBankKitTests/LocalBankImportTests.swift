import Foundation
import Testing

@testable import QBankKit

/// Importing a file into the bank on the phone: where it goes, what it stores, and what it asks the person when a set of the same name is already there. Invented data only.
@Suite struct LocalBankImportTests {
    private func words(_ answer: (status: Int, body: JSONValue)) -> String {
        "\(answer.status) \(answer.body["error"]?.stringValue ?? "") \(answer.body["message"]?.stringValue ?? "")"
    }

    private func count(_ harness: LocalBankHarness, _ table: String, _ condition: String = "1 = 1") throws -> Int {
        try harness.store.run("SELECT count(*) AS n FROM \(table) WHERE \(condition)")[0].int("n") ?? 0
    }

    // MARK: The check

    @Test func theCheckReadsOnlyTheFile() async throws {
        let harness = try LocalBankHarness()
        let source = Files.make("Invented Sleep", [Files.single("S1"), Files.single("S2")], terms: ["rem": ["REM", "Dreaming sleep."]], description: "  A few questions. ")
        let before = try harness.rows("SELECT * FROM folder")
        let report = try await harness.send("POST", "/api/imports/check", .object(["source": .string(source)]))
        #expect(report.status == 200)
        #expect(report.body["ok"] == .bool(true) && report.body["title"] == .string("Invented Sleep") && report.body["description"] == .string("A few questions."))
        #expect(report.body["questionCount"] == .number(2) && report.body["termCount"] == .number(1) && report.body["kind"] == .string("practice"))
        #expect(report.body["formats"] == .array([.object(["type": .string("single"), "label": .string("Single answer"), "count": .number(2)])]))
        #expect(try harness.rows("SELECT * FROM folder") == before)
        #expect(try count(harness, "practice_set") == 0)

        let broken = try await harness.send("POST", "/api/imports/check", .object(["source": .string("not json")]))
        #expect(broken.body["ok"] == .bool(false) && broken.body["title"] == .null)
        #expect(broken.body["errors"]?.arrayValue?.first?.stringValue == "This is not valid JSON: Unexpected token 'o', \"not json\" is not valid JSON. Ask your AI chat to resend only the JSON block.")
        #expect(words(try await harness.send("POST", "/api/imports/check", .object([:]))) == "400 invalid_request Check the fields and try again.")
        #expect(words(try await harness.send("POST", "/api/imports/check", .object(["source": .number(1)]))) == "400 invalid_request Check the fields and try again.")
    }

    // MARK: A first import

    @Test func aFirstImportFilesTheSetInUnsortedAndStoresWhatTheFileSays() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let question = Files.single("Q1", extra: ["stem": .string("  Stem. "), "topic": .string("Rest"), "diff": .string("3"), "terms": .array([.string("rem"), .string("nap")])])
        let source = Files.make("Invented Sleep", [question, Files.single("Q2", ask: "Which else?")], terms: ["rem": ["REM", "Dreaming sleep."]], description: "Sleep.")
        let imported = try await harness.importFile(source, into: course)
        #expect(imported.status == 201)
        let setID = try #require(imported.body["setId"]?.stringValue)
        #expect(imported.body["kind"] == .string("imported") && imported.body["setKind"] == .string("practice") && imported.body["weekLabel"] == .string("Unsorted"))
        #expect(imported.body["courseCode"] == .string("NURS 101") && imported.body["examPageId"] == .null && imported.body["importedByAgent"] == .null)
        #expect(imported.body["questionCount"] == .number(2) && imported.body["termCount"] == .number(1))
        #expect(imported.body["warnings"]?.arrayValue?.contains(.string("Question 1 (Q1): term \"nap\" has no definition and will be skipped")) == true, "\(imported.body["warnings"] ?? .null)")

        let set = try harness.store.run("SELECT * FROM practice_set WHERE id = ?", [.text(setID)])[0]
        #expect(set.text("title") == "Invented Sleep" && set.text("description") == "Sleep." && set.text("week_label") == "Unsorted" && set.bool("is_current") == true)
        #expect(set.text("lineage_id") == setID && set.text("replaced_at") == nil && set.text("kind") == "practice" && set.int("sort_order") == 1)
        #expect(set.text("file_hash") == ImportHash.fileHash(source))
        let stats = try JSParser.parse(try #require(set.text("stats")))
        #expect(stats.record?["questionCount"] == .number(2) && stats.record?["byType"]?.record?["single"] == .number(2))
        let rows = try harness.store.run("SELECT * FROM question WHERE set_id = ? ORDER BY position", [.text(setID)])
        #expect(rows.map { $0.text("public_id") } == ["Q1", "Q2"] && rows.map { $0.int("position") } == [1, 2])
        #expect(rows[0].text("stem") == "Stem." && rows[0].text("topic") == "Rest" && rows[0].int("difficulty") == 3 && rows[0].text("week_label") == "Unsorted")
        #expect(rows[0].text("term_keys") == "[\"rem\"]" && rows[0].text("cj") == nil && rows[1].text("stem") == "")
        #expect(rows[0].text("lineage_id") != rows[1].text("lineage_id") && rows[0].text("content_hash")?.count == 64)
        let terms = try harness.store.run("SELECT key, term, meaning FROM term WHERE set_id = ?", [.text(setID)])
        #expect(terms.map { $0.text("key") } == ["rem"] && terms[0].text("meaning") == "Dreaming sleep.")
        let folders = try harness.store.run("SELECT name, sort_order, course_exam_id FROM folder")
        #expect(folders.map { $0.text("name") } == ["Unsorted"] && folders[0].text("course_exam_id") == nil)
    }

    @Test func unsortedIsMadeAtTheTopOfTheFoldersListAndUsedAgain() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let week = try await harness.send("POST", "/api/courses/\(course)/folders", .object(["name": .string("Week 1")]))
        let first = try await harness.importFile(Files.make("One", [Files.single("a")]), into: course)
        let second = try await harness.importFile(Files.make("Two", [Files.single("a")]), into: course)
        #expect(first.body["folderId"] == second.body["folderId"] && first.body["folderId"] != week.body["id"])
        let order = try harness.store.run("SELECT name FROM folder ORDER BY sort_order").map { $0.text("name") }
        #expect(order == ["Unsorted", "Week 1"], "the first import makes Unsorted above the folders already there")
        #expect(try count(harness, "folder") == 2)
    }

    @Test func aFolderIsChosenByIdOrByNameAndANameIsFoundOrMade() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let week = try await harness.send("POST", "/api/courses/\(course)/folders", .object(["name": .string("Week 1")]))
        let weekID = try #require(week.body["id"])
        let byID = try await harness.importFile(Files.make("A", [Files.single("a")]), into: course, folder: weekID)
        #expect(byID.status == 201 && byID.body["folderId"] == weekID && byID.body["folderName"] == .string("Week 1"))
        let byName = try await harness.importFile(Files.make("B", [Files.single("a")]), into: course, folderName: " week 1 ")
        #expect(byName.body["folderId"] == weekID, "a name finds the folder of that name, ignoring case")
        let made = try await harness.importFile(Files.make("C", [Files.single("a")]), into: course, folderName: "Week 2")
        #expect(made.body["folderName"] == .string("Week 2") && made.body["folderId"] != weekID)
        let legacy = try await harness.send(
            "POST", "/api/imports", .object(["source": .string(Files.make("D", [Files.single("a")])), "courseId": .string(course), "weekLabel": .string("Week 3")]))
        #expect(legacy.status == 201 && legacy.body["folderName"] == .string("Week 3"), "weekLabel is the older name for folderName")
        let order = try harness.store.run("SELECT name FROM folder ORDER BY sort_order").map { $0.text("name") }
        #expect(order == ["Week 1", "Week 2", "Week 3"], "a new named folder goes to the end")

        // A folder name on a page is not the Folders list's: the one on no page is preferred, and a single one on a page is still found.
        let page = try await harness.send("POST", "/api/courses/\(course)/course-exams", .object(["name": .string("Exam 1"), "folderIds": .array([weekID])]))
        #expect(page.status == 201)
        let onPage = try await harness.importFile(Files.make("E", [Files.single("a")]), into: course, folderName: "Week 1")
        #expect(onPage.body["folderId"] == weekID && onPage.body["examPageId"]?.stringValue != nil)
    }

    @Test func anExamSetIsFiledAsTheFoldersExamBank() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let exam = try await harness.importFile(Files.make("Exam bank", [Files.single("E1", extra: ["twinOf": .string(" Q1 ")])], kind: "exam"), into: course)
        #expect(exam.body["setKind"] == .string("exam"))
        let row = try harness.store.run("SELECT twin_of FROM question")[0]
        #expect(row.text("twin_of") == "Q1")
        let detail = try await harness.send("GET", "/api/courses/\(course)")
        #expect(detail.body["examQuestionCount"] == .number(1) && detail.body["questionCount"] == .number(0), "an exam set is never listed for practice")
    }

    // MARK: A set of the same name

    @Test func aSetOfTheSameNameIsAskedAboutAndNothingIsWritten() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let first = try await harness.importFile(Files.make("Sleep", [Files.single("a"), Files.single("b")]), into: course, folderName: "Week 1")
        let before = try harness.rows("SELECT * FROM practice_set") + (try harness.rows("SELECT * FROM question")) + (try harness.rows("SELECT * FROM folder"))
        let asked = try await harness.importFile(Files.make("Sleep", [Files.single("a")]), into: course, folderName: "Week 9")
        #expect(asked.status == 409)
        #expect(asked.body["conflict"] == .bool(true) && asked.body["setId"] == first.body["setId"] && asked.body["folderName"] == .string("Week 1"))
        #expect(asked.body["existingQuestionCount"] == .number(2) && asked.body["incomingQuestionCount"] == .number(1) && asked.body["courseTitle"] == .string("Invented Nursing"))
        #expect(asked.body["weekLabel"] == .string("Week 1") && asked.body["courseCode"] == .string("NURS 101"))
        let after = try harness.rows("SELECT * FROM practice_set") + (try harness.rows("SELECT * FROM question")) + (try harness.rows("SELECT * FROM folder"))
        #expect(after == before, "the question asked nothing, and the folder Week 9 was not made")
    }

    @Test func replaceMakesANewVersionInTheSameFolderAndKeepsTheOldOneAndItsAnswers() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let first = try await harness.importFile(
            Files.make("Sleep", [Files.single("a"), Files.single("b"), Files.single("c")], terms: ["rem": ["REM", "Old."]]), into: course, folderName: "Week 1")
        let oldID = try #require(first.body["setId"]?.stringValue)
        let oldLineages = try harness.store.run("SELECT public_id, lineage_id FROM question WHERE set_id = ? ORDER BY position", [.text(oldID)]).map { ($0.text("public_id") ?? "", $0.text("lineage_id") ?? "") }
        let frozen = try harness.rows("SELECT * FROM folder") + (try harness.rows("SELECT id, course_id, lineage_id, title, description, week_label, folder_id, sort_order, imported_at, file_hash, stats, kind FROM practice_set"))
        let questions = try harness.rows("SELECT * FROM question")
        let terms = try harness.rows("SELECT * FROM term")

        harness.set(Date(timeIntervalSince1970: 1_700_100_000))
        let revised = Files.make("Sleep", [Files.single("a"), Files.single("b", ask: "A reworded question?"), Files.single("d")], terms: ["rem": ["REM", "New."]])
        let replaced = try await harness.importFile(revised, into: course, folderName: "Week 7", decision: "replace")
        #expect(replaced.status == 201 && replaced.body["kind"] == .string("replaced"), "\(replaced.body)")
        #expect(replaced.body["folderName"] == .string("Week 1"), "a replacement stays in its folder, whatever folder the import names")
        let newID = try #require(replaced.body["setId"]?.stringValue)

        let old = try harness.store.run("SELECT * FROM practice_set WHERE id = ?", [.text(oldID)])[0]
        let new = try harness.store.run("SELECT * FROM practice_set WHERE id = ?", [.text(newID)])[0]
        #expect(old.bool("is_current") == false && old.text("replaced_at") == "2023-11-16T02:00:00.000Z")
        #expect(new.bool("is_current") == true && new.text("lineage_id") == old.text("lineage_id") && new.int("sort_order") == old.int("sort_order"))
        #expect(new.text("folder_id") == old.text("folder_id") && new.text("week_label") == "Week 1")
        let lineages = try harness.store.run("SELECT public_id, lineage_id FROM question WHERE set_id = ? ORDER BY position", [.text(newID)]).map { ($0.text("public_id") ?? "", $0.text("lineage_id") ?? "") }
        #expect(lineages[0] == oldLineages[0], "a question the file did not change keeps its lineage, so the answers follow it")
        #expect(lineages[1].0 == "b" && lineages[1].1 != oldLineages[1].1, "a reworded question is a new one")
        #expect(lineages[2].1 != oldLineages[2].1 && lineages.map(\.1).allSatisfy { !$0.isEmpty })

        // Nothing the person had was deleted, moved or renamed: the earlier version, its questions and terms are as they were.
        let nowFrozen = try harness.rows("SELECT * FROM folder") + (try harness.rows("SELECT id, course_id, lineage_id, title, description, week_label, folder_id, sort_order, imported_at, file_hash, stats, kind FROM practice_set WHERE id = '\(oldID)'"))
        #expect(nowFrozen == frozen.filter { _ in true }.prefix(nowFrozen.count).map { $0 })
        #expect(try harness.rows("SELECT * FROM question WHERE set_id = '\(oldID)'") == questions)
        #expect(try harness.rows("SELECT * FROM term WHERE set_id = '\(oldID)'") == terms)
        let detail = try await harness.send("GET", "/api/courses/\(course)")
        let set = try #require(detail.body["folders"]?.arrayValue?.first?["sets"]?.arrayValue?.first)
        #expect(set["id"] == .string(newID) && set["status"] == .string("replaced") && set["canRestore"] == .bool(true) && set["questionCount"] == .number(3))
    }

    @Test func addBesideKeepsBothSetsCurrent() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let first = try await harness.importFile(Files.make("Sleep", [Files.single("a")]), into: course)
        let beside = try await harness.importFile(Files.make("Sleep", [Files.single("b"), Files.single("c")]), into: course, decision: "separate")
        #expect(beside.status == 201 && beside.body["kind"] == .string("imported"))
        #expect(try count(harness, "practice_set", "is_current = 1 AND title = 'Sleep'") == 2)
        let rows = try harness.store.run("SELECT id, lineage_id, sort_order FROM practice_set ORDER BY sort_order")
        #expect(rows.map { $0.int("sort_order") } == [1, 2] && rows[1].text("lineage_id") == rows[1].text("id") && rows[0].text("id") == first.body["setId"]?.stringValue)
        let again = try await harness.importFile(Files.make("Sleep", [Files.single("z")]), into: course)
        #expect(again.status == 409, "with two of that name there, the newest is the one asked about")
        #expect(again.body["setId"] == beside.body["setId"])
    }

    @Test func aPracticeSetAndAnExamSetOfOneNameAreNotTheSame() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        _ = try await harness.importFile(Files.make("Perfusion", [Files.single("a")]), into: course)
        let exam = try await harness.importFile(Files.make("Perfusion", [Files.single("a")], kind: "exam"), into: course)
        #expect(exam.status == 201 && exam.body["kind"] == .string("imported"))
        let sameName = try await harness.importFile(Files.make("perfusion", [Files.single("a")]), into: course)
        #expect(sameName.status == 201, "a name is matched as written")
    }

    // MARK: Restore

    @Test func restoreBringsBackTheVersionAReplacementSetAsideAndGoesBackAgain() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let first = try await harness.importFile(Files.make("Sleep", [Files.single("a"), Files.single("b")]), into: course)
        harness.set(Date(timeIntervalSince1970: 1_700_100_000))
        let second = try await harness.importFile(Files.make("Sleep", [Files.single("a")]), into: course, decision: "replace")
        let firstID = try #require(first.body["setId"]?.stringValue)
        let secondID = try #require(second.body["setId"]?.stringValue)

        harness.set(Date(timeIntervalSince1970: 1_700_200_000))
        let restored = try await harness.send("POST", "/api/practice-sets/\(secondID)/restore")
        #expect(restored.status == 200 && restored.body["id"] == .string(firstID) && restored.body["status"] == .string("restored") && restored.body["canRestore"] == .bool(true))
        #expect(restored.body["questionCount"] == .number(2) && restored.body["run"] == .string("new") && restored.body["sitting"] == .null)
        #expect(restored.body["activeSince"] == .string("2023-11-17T05:46:40.000Z") && restored.body["questionIds"]?.arrayValue?.count == 2)
        #expect(try count(harness, "practice_set", "is_current = 1") == 1, "restoring deletes nothing")
        #expect(try count(harness, "practice_set") == 2, "restoring deletes nothing")
        let old = try harness.store.run("SELECT replaced_at, is_current FROM practice_set WHERE id = ?", [.text(secondID)])[0]
        #expect(old.bool("is_current") == false && old.text("replaced_at") == "2023-11-17T05:46:40.000Z")
        #expect(try harness.store.run("SELECT replaced_at FROM practice_set WHERE id = ?", [.text(firstID)])[0].text("replaced_at") == nil)

        #expect(words(try await harness.send("POST", "/api/practice-sets/\(secondID)/restore")) == "404 request_refused That set is not the current version.")
        let back = try await harness.send("POST", "/api/practice-sets/\(firstID)/restore")
        #expect(back.body["id"] == .string(secondID) && back.body["status"] == .string("replaced"))
    }

    @Test func aSetWithNoEarlierVersionHasNothingToRestore() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let only = try await harness.importFile(Files.make("Sleep", [Files.single("a")]), into: course)
        let id = try #require(only.body["setId"]?.stringValue)
        #expect(words(try await harness.send("POST", "/api/practice-sets/\(id)/restore")) == "400 request_refused This set has no previous version to restore.")
        #expect(words(try await harness.send("POST", "/api/practice-sets/ee000000-0000-4000-8000-000000000777/restore")) == "404 request_refused That set is not in the app.")
        #expect(words(try await harness.send("POST", "/api/practice-sets/nope/restore")) == "400 invalid_request Check the fields and try again.")
    }

    // MARK: A new course or topic

    @Test func aNewCourseIsMadeInItsSemesterAndASemesterThePersonLacksIsMadeToo() async throws {
        let harness = try LocalBankHarness()
        let source = Files.make("Sleep", [Files.single("a")])
        let made = try await harness.send(
            "POST", "/api/imports",
            .object([
                "source": .string(source),
                "newCourse": .object(["code": .string(" PSYC 200 "), "title": .string("Invented Psychology"), "semesterNumber": .number(2), "semesterName": .string("Spring")]),
            ]))
        #expect(made.status == 201 && made.body["courseCode"] == .string("PSYC 200"))
        let semesters = try harness.store.run("SELECT number, name FROM semester")
        #expect(semesters.map { $0.int("number") } == [2] && semesters.map { $0.text("name") } == ["Spring"])
        #expect(try harness.store.run("SELECT kind, title FROM course")[0].text("kind") == "course")

        let again = try await harness.send(
            "POST", "/api/imports",
            .object(["source": .string(Files.make("Other", [Files.single("a")])), "newCourse": .object(["code": .string("PSYC 201"), "title": .string("More"), "semesterNumber": .number(2)])]))
        #expect(again.status == 201)
        #expect(try count(harness, "semester") == 1, "the semester of that number is used")
        let taken = try await harness.send(
            "POST", "/api/imports",
            .object(["source": .string(source), "newCourse": .object(["code": .string("psyc 200"), "title": .string("Clash"), "semesterNumber": .number(2)])]))
        #expect(words(taken) == "409 request_refused This semester already has a course with the code psyc 200.")
        #expect(try count(harness, "course") == 2)
        #expect(try count(harness, "practice_set") == 2)
    }

    @Test func aRefusedImportLeavesNoSemesterOrCourseBehind() async throws {
        let harness = try LocalBankHarness()
        let source = Files.make("Sleep", [Files.single("a")])
        let blank = try await harness.send(
            "POST", "/api/imports", .object(["source": .string(source), "newCourse": .object(["code": .string(" "), "title": .string("Name"), "semesterNumber": .number(3)])]))
        #expect(words(blank) == "400 request_refused Course code is required.")
        #expect(try count(harness, "semester") == 0, "the semester the import began to make is undone")
        #expect(try count(harness, "course") == 0, "the semester the import began to make is undone")
        let badNumber = try await harness.send(
            "POST", "/api/imports", .object(["source": .string(source), "newCourse": .object(["code": .string("X"), "title": .string("Name"), "semesterNumber": .number(4)])]))
        #expect(words(badNumber) == "400 request_refused A semester is 1, 2, or 3.")
        let unnamed = try await harness.send(
            "POST", "/api/imports",
            .object(["source": .string(source), "newCourse": .object(["code": .string("X"), "title": .string("Name"), "semesterNumber": .number(1), "semesterName": .string(" ")])]))
        #expect(words(unnamed) == "400 request_refused Name is required.")
        #expect(try count(harness, "semester") == 0)
    }

    @Test func aNewTopicIsMadeOnceByName() async throws {
        let harness = try LocalBankHarness()
        let made = try await harness.send(
            "POST", "/api/imports", .object(["source": .string(Files.make("Verbs", [Files.single("a")])), "newTopic": .object(["title": .string(" Spanish ")])]))
        #expect(made.status == 201 && made.body["courseCode"] == .string("") && made.body["weekLabel"] == .string("Unsorted"))
        let row = try harness.store.run("SELECT kind, title, semester_id FROM course")[0]
        #expect(row.text("kind") == "topic" && row.text("title") == "Spanish" && row.text("semester_id") == nil)
        let clash = try await harness.send(
            "POST", "/api/imports", .object(["source": .string(Files.make("Nouns", [Files.single("a")])), "newTopic": .object(["title": .string("spanish")])]))
        #expect(words(clash) == "409 request_refused You already have a topic named Spanish.")
        #expect(try count(harness, "course") == 1)
        #expect(try count(harness, "practice_set") == 1)
    }

    // MARK: Refusals

    @Test func eachRefusalIsInTheServersWords() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let source = Files.make("Sleep", [Files.single("a")])
        let other = "ee000000-0000-4000-8000-000000000777"
        let newCourse: JSONValue = .object(["code": .string("X"), "title": .string("T"), "semesterNumber": .number(1)])
        let refusals: [([String: JSONValue], String)] = [
            (["source": .string(source)], "400 request_refused Choose a course."),
            (["source": .string(source), "courseId": .string(course), "newCourse": newCourse], "400 request_refused Choose a course or a new course, not both."),
            (["source": .string(source), "courseId": .string(course), "newTopic": .object(["title": .string("T")])], "400 request_refused Choose one place for the set: a course, a topic, a new course, or a new topic."),
            (["source": .string(source), "newCourse": newCourse, "newTopic": .object(["title": .string("T")])], "400 request_refused Choose one place for the set: a course, a topic, a new course, or a new topic."),
            (["source": .string(source), "courseId": .string(course), "folderId": .string(other), "folderName": .string("W")], "400 request_refused Choose a folder or a folder name, not both."),
            (["source": .string(source), "newCourse": newCourse, "folderId": .string(other)], "400 request_refused A new course has no folders yet. Name a folder, or leave it for Unsorted."),
            (["source": .string(source), "newTopic": .object(["title": .string("T")]), "folderId": .string(other)], "400 request_refused A new topic has no folders yet. Name a folder, or leave it for Unsorted."),
            (["source": .string(source), "courseId": .string(course), "folderName": .string("  ")], "400 request_refused Folder name is required."),
            (["source": .string(source), "courseId": .string(course), "folderName": .string(String(repeating: "x", count: 81))], "400 request_refused Folder name is too long."),
            (["source": .string(source), "courseId": .string(course), "title": .string(" ")], "400 request_refused Set name is required."),
            (["source": .string(source), "courseId": .string(course), "title": .string(String(repeating: "x", count: 201))], "400 request_refused Set name is too long."),
            (["source": .string(source), "courseId": .string(course), "folderId": .string(other)], "400 request_refused That folder is not in this course."),
            (["source": .string(source), "courseId": .string(other)], "404 request_refused That course is not in the app."),
            (["source": .string(source), "newTopic": .object(["title": .string(" ")])], "400 request_refused Topic name is required."),
            (["source": .string(source), "courseId": .string(course), "decision": .string("merge")], "400 invalid_request Check the fields and try again."),
            (["source": .string(source), "courseId": .string(course), "title": .null], "400 invalid_request Check the fields and try again."),
            (["source": .string(source), "courseId": .string("not-an-id")], "400 invalid_request Check the fields and try again."),
            (["courseId": .string(course)], "400 invalid_request Check the fields and try again."),
            (["source": .string(source), "newCourse": .object(["code": .string("X")])], "400 invalid_request Check the fields and try again."),
            (["source": .string(source), "newCourse": .object(["code": .string("X"), "title": .string("T"), "semesterNumber": .number(1.5)])], "400 invalid_request Check the fields and try again."),
        ]
        for (body, expected) in refusals {
            #expect(words(try await harness.send("POST", "/api/imports", .object(body))) == expected, "\(body.keys.sorted())")
        }
        #expect(try count(harness, "practice_set") == 0, "no refusal wrote a set or a folder")
        #expect(try count(harness, "folder") == 0, "no refusal wrote a set or a folder")
    }

    @Test func anArchivedOrDeletedCourseTakesNoImport() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        _ = try await harness.send("PATCH", "/api/courses/\(course)", .object(["archived": .bool(true)]))
        #expect(words(try await harness.importFile(Files.make("A", [Files.single("a")]), into: course)) == "400 request_refused That course is archived. Unarchive it before importing.")
        try harness.store.run("UPDATE course SET deleted_at = '2026-11-22T20:00:00.000Z', deletion_id = 'dd000000-0000-4000-8000-000000000001'")
        #expect(words(try await harness.importFile(Files.make("A", [Files.single("a")]), into: course)) == "404 request_refused That course is not in the app.")
        #expect(words(try await harness.importFile("not json", into: course)) == "404 request_refused That course is not in the app.", "a deleted course is refused before the file is read")
    }

    @Test func aFileThatFailsTheCheckIsRefusedWithItsErrorsAndWritesNothing() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let broken = Files.make("Broken", [Files.single("Q1", extra: ["cj": .string("Analyze")]), Files.single("Q2", right: 0, extra: ["options": .array([.object(["t": .string("Only")])])])])
        let refused = try await harness.importFile(broken, into: course)
        #expect(refused.status == 400 && refused.body["error"] == .string("invalid_import"))
        #expect(refused.body["message"] == .string("Question 2 (Q2): needs at least 2 options"))
        #expect(refused.body["errors"] == .array([.string("Question 2 (Q2): needs at least 2 options")]))
        #expect(refused.body["warnings"]?.arrayValue != nil, "a refusal carries the warnings too")
        #expect(try count(harness, "folder") == 0)
        #expect(try count(harness, "practice_set") == 0)
        let unknown = try await harness.importFile("not json", into: "ee000000-0000-4000-8000-000000000777")
        #expect(unknown.status == 400 && unknown.body["error"] == .string("invalid_import"), "a course that names nothing is refused after the file is read")
    }

    @Test func theSetNameCanBeChangedAndAFileWithNoTitleIsImportedQuestions() async throws {
        let harness = try LocalBankHarness()
        let course = try await harness.makeCourse()
        let titled = try await harness.importFile(Files.make("Sleep", [Files.single("a")]), into: course, title: "  My name  ")
        #expect(titled.body["title"] == .string("My name"))
        let bare = try await harness.importFile(Files.text(.array([Files.single("a")])), into: course)
        #expect(bare.body["title"] == .string("Imported questions"))
        let fenced = try await harness.importFile("```json\n" + Files.make("Fenced", [Files.single("a")]) + "\n```", into: course)
        #expect(fenced.status == 201 && fenced.body["title"] == .string("Fenced"))
    }
}
