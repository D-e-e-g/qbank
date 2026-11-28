import Foundation
import Testing

@testable import QBankKit

/// Two runs with different prefixes import the same question file through the local engine.
struct CombineWorld {
    let study: StudySet
    let folder: String
    let page: String
    let topic: String
    var store: LocalStore { study.harness.store }

    static let date = ArchiveWorld.date
    static let later = "2027-01-01T00:00:00.000Z"
    static let newest = "2027-02-01T00:00:00.000Z"
    static let stamp = "opaque/server=1"

    static func make(_ prefix: String, count: Int = 2) async throws -> Self {
        let bank = try LocalBankHarness(store: LocalStore.inMemory(), idPrefix: prefix)
        let course = try await bank.makeCourse()
        let file = Files.make("Study", (1...count).map { Files.single("Q\($0)") }, terms: ["key": ["Term", "Meaning"]])
        let imported = try await bank.importFile(file, into: course, folderName: "Week")
        let set = try #require(imported.body["setId"]?.stringValue)
        let folder = try #require(imported.body["folderId"]?.stringValue)
        let page = try await bank.send("POST", "/api/courses/\(course)/course-exams", .object(["name": .string("Page"), "folderIds": .array([.string(folder)])]))
        let topic = try await bank.send("POST", "/api/topics", .object(["title": .string("Topic")]))
        let questions = try await ArchiveWorld.questionIDs(bank, set)
        return try Self(
            study: StudySet(harness: bank, course: course, setID: set, questions: questions), folder: folder,
            page: #require(page.body["id"]?.stringValue), topic: #require(topic.body["id"]?.stringValue))
    }

    func copy() throws -> Self {
        let copy = try LocalStore.inMemory()
        try BankArchive.read(Self.archive(store), into: copy)
        let harness = LocalBankHarness(store: copy, idPrefix: "bb000000")
        return Self(study: StudySet(harness: harness, course: study.course, setID: study.setID, questions: study.questions), folder: folder, page: page, topic: topic)
    }

    static func archive(_ store: LocalStore, server: Bool = false) throws -> Data {
        let data = try BankArchive.write(from: store, at: date)
        guard server else { return data }
        var document = try ArchiveWorld.parsed(data)
        document["stamp"] = stamp
        document["writtenBy"] = "server"
        return try ArchiveWorld.serialized(document)
    }

    func combine(into server: Self, at date: Date = Self.date) throws -> (LocalStore, BankCombine.Ledger) {
        let result = try BankCombine.combine(phone: Self.archive(store), server: Self.archive(server.store, server: true), at: date)
        let copy = try LocalStore.inMemory()
        try BankArchive.read(result.archive, into: copy)
        return (copy, result.ledger)
    }
}
