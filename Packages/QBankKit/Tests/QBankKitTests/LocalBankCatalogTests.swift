import Foundation
import Testing

@testable import QBankKit

/// The catalog rules the transcripts do not reach: topics, the words of a refusal, and what the
/// engine does with a request it does not serve. Invented data only.
@Suite struct LocalBankCatalogTests {
    private func error(_ answer: (status: Int, body: JSONValue)) -> String {
        "\(answer.status) \(answer.body["error"]?.stringValue ?? "") \(answer.body["message"]?.stringValue ?? "")"
    }

    private func topic(_ harness: LocalBankHarness, _ title: String) async throws -> String {
        let made = try await harness.send("POST", "/api/topics", .object(["title": .string(title)]))
        #expect(made.status == 201)
        return try #require(made.body["id"]?.stringValue)
    }

    @Test func topicsAreMadeInOrderAndNamedOnce() async throws {
        let harness = try LocalBankHarness()
        let first = try await topic(harness, "  Pharmacology  ")
        let second = try await topic(harness, "Spanish Verbs")
        #expect(first == "ee000000-0000-4000-8000-000000000001", "ids come from the generator the bank was given")
        let listed = try await harness.send("GET", "/api/semesters")
        #expect(listed.body["topics"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Pharmacology", "Spanish Verbs"])
        #expect(listed.body["topics"]?.arrayValue?.compactMap { $0["sortOrder"] } == [.number(1), .number(2)])
        #expect(listed.body["semesters"]?.arrayValue?.isEmpty == true)

        let taken = try await harness.send("POST", "/api/topics", .object(["title": .string("spanish verbs")]))
        #expect(error(taken) == "409 request_refused You already have a topic named Spanish Verbs.")
        let blank = try await harness.send("POST", "/api/topics", .object(["title": .string(" ")]))
        #expect(error(blank) == "400 request_refused Topic name is required.")

        let renamed = try await harness.send("PATCH", "/api/courses/\(second)", .object(["title": .string("Pharmacology")]))
        #expect(error(renamed) == "409 request_refused You already have a topic named Pharmacology.")
        let coded = try await harness.send("PATCH", "/api/courses/\(second)", .object(["code": .string("X")]))
        #expect(error(coded) == "400 request_refused A topic has no course code or semester. Change its name instead.")
        let archived = try await harness.send("PATCH", "/api/courses/\(second)", .object(["archived": .bool(true)]))
        #expect(archived.status == 200 && archived.body["archivedAt"]?.stringValue != nil)
    }

    @Test func aTopicOrderMustNameEveryTopicOnce() async throws {
        let harness = try LocalBankHarness()
        let first = try await topic(harness, "One")
        let second = try await topic(harness, "Two")
        let stale = try await harness.send("PUT", "/api/topic-order", .object(["topicIds": .array([.string(first)])]))
        #expect(error(stale) == "409 request_refused Your topics changed since this list was shown. Reload and try again.")
        let doubled = try await harness.send("PUT", "/api/topic-order", .object(["topicIds": .array([.string(first), .string(first)])]))
        #expect(doubled.status == 409)
        let swapped = try await harness.send("PUT", "/api/topic-order", .object(["topicIds": .array([.string(second), .string(first)])]))
        #expect(swapped.body["topics"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Two", "One"])
    }

    @Test func aTopicReadsAsACourseWithNoSemester() async throws {
        let harness = try LocalBankHarness()
        let id = try await topic(harness, "Pharmacology")
        let page = try await harness.send("POST", "/api/courses/\(id)/course-exams", .object(["name": .string("Page 1"), "linkUrl": .string("primer.example.com/a")]))
        #expect(page.status == 201 && page.body["linkUrl"]?.stringValue == "https://primer.example.com/a")
        let folder = try await harness.send("POST", "/api/courses/\(id)/folders", .object(["name": .string("Loose"), "examPageId": .null]))
        #expect(folder.status == 201)
        let detail = try await harness.send("GET", "/api/courses/\(id)")
        #expect(detail.body["kind"]?.stringValue == "topic" && detail.body["semester"] == .null && detail.body["folderCount"] == .number(1))
        #expect(detail.body["exams"]?.arrayValue?.count == 1)
        let clash = try await harness.send("POST", "/api/courses/\(id)/folders", .object(["name": .string("loose")]))
        #expect(error(clash) == "409 request_refused Pharmacology already has a folder named Loose.")
    }

    @Test func aPageSwapsAFolderForOneOfTheSameNameInTheFoldersList() async throws {
        let harness = try LocalBankHarness()
        let id = try await topic(harness, "Pharmacology")
        let page = try #require(try await harness.send("POST", "/api/courses/\(id)/course-exams", .object(["name": .string("Exam 1")])).body["id"]?.stringValue)
        let onPage = try await harness.send("POST", "/api/courses/\(id)/folders", .object(["name": .string("First Pass"), "examPageId": .string(page)]))
        let loose = try await harness.send("POST", "/api/courses/\(id)/folders", .object(["name": .string("First Pass"), "examPageId": .null]))
        let leaving = try #require(onPage.body["id"]?.stringValue)
        let arriving = try #require(loose.body["id"]?.stringValue)

        let swapped = try await harness.send("PUT", "/api/course-exams/\(page)", .object(["name": .string("Exam 1"), "folderIds": .array([.string(arriving)])]))
        #expect(swapped.status == 200)
        let detail = try await harness.send("GET", "/api/courses/\(id)")
        let folders = try #require(detail.body["folders"]?.arrayValue)
        #expect(folders.compactMap { $0["id"]?.stringValue } == [arriving, leaving])
        #expect(folders.compactMap { $0["name"]?.stringValue } == ["First Pass", "First Pass"])
        #expect(folders.map { $0["examPageId"] } == [.string(page), .null])
    }

    @Test func aRefusedWriteLeavesNothingBehind() async throws {
        let harness = try LocalBankHarness()
        let id = try await topic(harness, "Pharmacology")
        let before = try harness.store.run("SELECT count(*) AS n FROM course_exam")[0].int("n")
        let refused = try await harness.send("POST", "/api/courses/\(id)/course-exams", .object(["name": .string("Page 1"), "folderIds": .array([.string("f0000000-0000-4000-8000-000000000999")])]))
        #expect(error(refused) == "400 request_refused That folder is not in this course.")
        #expect(try harness.store.run("SELECT count(*) AS n FROM course_exam")[0].int("n") == before, "the page the refused request began to make is undone")
    }

    @Test func aRequestOffTheContractIsInvalid() async throws {
        let harness = try LocalBankHarness()
        let words = "400 invalid_request Check the fields and try again."
        #expect(error(try await harness.send("POST", "/api/semesters", .object(["number": .string("1")]))) == words)
        #expect(error(try await harness.send("POST", "/api/semesters", .object(["number": .number(1.5)]))) == words)
        #expect(error(try await harness.send("POST", "/api/semesters")) == words)
        #expect(error(try await harness.send("POST", "/api/topics", .object([:]))) == words)
        #expect(error(try await harness.send("GET", "/api/courses/not-an-id")) == words)
        #expect(error(try await harness.send("PUT", "/api/course-exams/ee000000-0000-4000-8000-000000000001", .object(["name": .string("A"), "badge": .string("gold")]))) == words)
    }

    @Test func missingThingsAreNotInTheApp() async throws {
        let harness = try LocalBankHarness()
        let missing = "ee000000-0000-4000-8000-000000000777"
        #expect(error(try await harness.send("GET", "/api/courses/\(missing)")) == "404 request_refused That course is not in the app.")
        #expect(error(try await harness.send("PATCH", "/api/semesters/\(missing)", .object([:]))) == "404 request_refused That semester is not in the app.")
        #expect(error(try await harness.send("PUT", "/api/course-exams/\(missing)", .object(["name": .string("A")]))) == "404 request_refused That page is not in the app.")
        #expect(error(try await harness.send("PATCH", "/api/folders/\(missing)", .object(["name": .string("A")]))) == "404 request_refused That folder is not in the app.")
        #expect(error(try await harness.send("POST", "/api/practice-sets/\(missing)/move", .object(["newFolderName": .string("A")]))) == "404 request_refused That set is not in the app.")
    }

    @Test func aPathNoFamilyServesIsA404InTheContractsShape() async throws {
        let harness = try LocalBankHarness()
        let answer = try await harness.send("POST", "/api/attempts", .object([:]))
        #expect(answer.status == 404 && answer.body["error"]?.stringValue == "not_found" && answer.body["message"]?.stringValue != nil)
        let wrongMethod = try await harness.send("DELETE", "/api/semesters")
        #expect(wrongMethod.status == 404)
    }

    @Test func theClockAndIdsAreTheOnesHandedIn() async throws {
        let harness = try LocalBankHarness()
        harness.set(Date(timeIntervalSince1970: 1_800_000_000.123))
        let semester = try await harness.send("POST", "/api/semesters", .object(["number": .number(2)]))
        #expect(semester.body["id"]?.stringValue == "ee000000-0000-4000-8000-000000000001")
        let created = try harness.store.run("SELECT created_at FROM semester")[0].text("created_at")
        #expect(created == "2027-01-15T08:00:00.123Z")
        let archived = try await harness.send("PATCH", "/api/semesters/ee000000-0000-4000-8000-000000000001", .object(["archived": .bool(true)]))
        #expect(archived.body["archivedAt"]?.stringValue == "2027-01-15T08:00:00.123Z")
    }
}
