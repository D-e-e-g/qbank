import Foundation
import Testing

@testable import QBankKit

@Suite("The phone's store")
struct LocalStoreTests {
    typealias Fixtures = StoreFixtures

    static let tableNames = [
        "attempt", "course", "course_exam", "folder", "practice_set", "question", "question_progress",
        "review_clear", "semester", "study_place", "study_session", "term",
    ]

    /// A step after the real ones, as a later release would add it.
    static func laterStep(_ number: Int) -> SchemaStep {
        SchemaStep(number: number, name: "test step \(number)", statements: ["ALTER TABLE course ADD COLUMN note\(number) TEXT"])
    }

    // MARK: Opening

    @Test func opensANewFileWithTheTwelveTablesAtTheLatestStep() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore.open(directory: directory)
        #expect(store.fileURL == directory.appendingPathComponent("bank.sqlite"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bank.sqlite").path))
        #expect(try store.schemaVersion == SchemaSteps.all.count)

        let tables = try store.run("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").compactMap { $0.text("name") }
        #expect(tables == Self.tableNames)
        #expect(try store.run("PRAGMA foreign_keys").first?.int("foreign_keys") == 1)
        #expect(try store.run("PRAGMA journal_mode").first?.text("journal_mode") == "delete")
    }

    @Test func reopeningKeepsTheRowsAndDoesNotRunTheStepsAgain() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LocalStore.open(directory: directory)
        try first.transaction { try Fixtures.insertStudiedCourse($0) }
        first.close()

        let second = try LocalStore.open(directory: directory)
        #expect(try Fixtures.count(second, "course") == 1)
        #expect(try Fixtures.count(second, "attempt") == 1)
        #expect(try second.schemaVersion == SchemaSteps.all.count)
    }

    @Test func anInMemoryStoreIsPrivateAndFullyMade() throws {
        let one = try LocalStore.inMemory()
        let two = try LocalStore.inMemory()
        #expect(one.fileURL == nil)
        try one.transaction { try Fixtures.insertSemester($0) }
        #expect(try Fixtures.count(one, "semester") == 1)
        #expect(try Fixtures.count(two, "semester") == 0)
        #expect(try Fixtures.shape(one) == Fixtures.shape(LocalStore.open(directory: Fixtures.temporaryDirectory().appendingPathComponent("a"))))
    }

    @Test func aStoreOfAKeyLivesInItsOwnFolderUnderBanks() throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore.open(key: "001234.abcdef0123456789.4321", in: root) // gitleaks:allow
        #expect(store.fileURL == root.appendingPathComponent("Banks/001234.abcdef0123456789.4321/bank.sqlite"))
        // Sign-out erases Accounts/<id>, never Banks.
        #expect(store.fileURL?.path.contains("/Accounts/") == false)
    }

    @Test(arguments: ["", ".", "..", ".hidden", "a/b", "a\\b", "a b", "../x", "é", String(repeating: "a", count: 129)])
    func refusesAKeyThatIsNotSafeAsAFolderName(key: String) {
        #expect(throws: StoreError.invalidKey(key)) { try LocalStore.open(key: key, in: Fixtures.temporaryDirectory()) }
    }

    @Test func closedStoreRefusesEveryCall() throws {
        let store = try LocalStore.inMemory()
        store.close()
        #expect(throws: StoreError.closed) { try store.run("SELECT 1") }
        #expect(throws: StoreError.closed) { try store.schemaVersion }
    }

    // MARK: Upgrading

    @Test func upgradesFromEveryEarlierStepToTheLatest() throws {
        let later = [Self.laterStep(SchemaSteps.all.count + 1), Self.laterStep(SchemaSteps.all.count + 2)]
        let steps = SchemaSteps.all + later
        let fresh = try LocalStore.inMemory(steps: steps)
        let expectedShape = try Fixtures.shape(fresh)

        // From a file with no step, from the file each step leaves, up to the one before the latest.
        for earlier in 0..<steps.count {
            let directory = Fixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let old = try LocalStore.open(directory: directory, steps: Array(steps.prefix(earlier)))
            #expect(try old.schemaVersion == earlier)
            if earlier >= 1 { try old.transaction { try Fixtures.insertStudiedCourse($0) } }
            old.close()

            let upgraded = try LocalStore.open(directory: directory, steps: steps)
            #expect(try upgraded.schemaVersion == steps.count, "from step \(earlier)")
            #expect(try Fixtures.shape(upgraded) == expectedShape, "from step \(earlier)")
            if earlier >= 1 {
                #expect(try Fixtures.count(upgraded, "course") == 1, "from step \(earlier)")
                #expect(try Fixtures.count(upgraded, "question") == 1, "from step \(earlier)")
                #expect(try Fixtures.count(upgraded, "attempt") == 1, "from step \(earlier)")
            }
        }
    }

    @Test func aStepThatFailsLeavesTheFileAtTheLastStepThatFinished() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = SchemaSteps.all
        let broken = SchemaStep(
            number: good.count + 1, name: "broken",
            statements: ["CREATE TABLE half_made (id TEXT)", "ALTER TABLE no_such_table ADD COLUMN x TEXT"])
        let before = try LocalStore.open(directory: directory, steps: good)
        try before.transaction { try Fixtures.insertStudiedCourse($0) }
        let shapeBefore = try Fixtures.shape(before)
        before.close()

        #expect(throws: StoreError.self) { try LocalStore.open(directory: directory, steps: good + [broken]) }

        let after = try LocalStore.open(directory: directory, steps: good)
        #expect(try after.schemaVersion == good.count)
        #expect(try Fixtures.shape(after) == shapeBefore)
        #expect(try Fixtures.count(after, "course") == 1)
    }

    @Test func refusesAFileFromANewerStepAndLeavesItAlone() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newer = SchemaSteps.all + [Self.laterStep(SchemaSteps.all.count + 1)]
        let made = try LocalStore.open(directory: directory, steps: newer)
        try made.transaction { try Fixtures.insertStudiedCourse($0) }
        made.close()

        #expect(throws: StoreError.newerSchema(found: newer.count, supported: SchemaSteps.all.count)) {
            try LocalStore.open(directory: directory)
        }
        let again = try LocalStore.open(directory: directory, steps: newer)
        #expect(try again.schemaVersion == newer.count)
        #expect(try Fixtures.count(again, "attempt") == 1)
    }

    @Test func stepsMustBeNumberedFromOneWithoutGaps() {
        let gap = [SchemaSteps.all[0], Self.laterStep(3)]
        #expect(throws: StoreError.invalidSteps) { try LocalStore.inMemory(steps: gap) }
        #expect(throws: StoreError.invalidSteps) { try LocalStore.inMemory(steps: [Self.laterStep(2)]) }
    }

    // MARK: Transactions

    struct Boom: Error {}

    @Test func aFailedTransactionChangesNothing() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertSemester($0) }

        #expect(throws: Boom.self) {
            try store.transaction { transaction in
                try Fixtures.insertCourse(transaction, 10, semester: 1)
                try transaction.execute("UPDATE semester SET name = 'Changed'")
                throw Boom()
            }
        }
        #expect(try Fixtures.count(store, "course") == 0)
        #expect(try store.run("SELECT name FROM semester").first?.text("name") == "Semester 1")
    }

    @Test func aRefusedRowRollsBackTheRowsBeforeItInTheSameTransaction() throws {
        let store = try LocalStore.inMemory()
        #expect(throws: StoreError.self) {
            try store.transaction { transaction in
                try Fixtures.insertSemester(transaction)
                try Fixtures.insertCourse(transaction, 10, semester: 1)
                // Names a semester that is not there: a foreign key refuses it.
                try Fixtures.insertCourse(transaction, 11, semester: 2)
            }
        }
        #expect(try Fixtures.count(store, "semester") == 0)
        #expect(try Fixtures.count(store, "course") == 0)
        // The store still works after a failure.
        try store.transaction { try Fixtures.insertSemester($0) }
        #expect(try Fixtures.count(store, "semester") == 1)
    }

    @Test func aFailedTransactionOnAFileChangesNothingAfterReopening() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore.open(directory: directory)
        try store.transaction { try Fixtures.insertStudiedCourse($0) }
        #expect(throws: Boom.self) {
            try store.transaction { transaction in
                try transaction.execute("DELETE FROM attempt")
                try transaction.execute("UPDATE course SET title = 'Gone'")
                throw Boom()
            }
        }
        store.close()
        let reopened = try LocalStore.open(directory: directory)
        #expect(try Fixtures.count(reopened, "attempt") == 1)
        #expect(try reopened.run("SELECT title FROM course").first?.text("title") == "Course 10")
    }

    @Test func aSavepointUndoesOnlyItsOwnChanges() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { transaction in
            try Fixtures.insertSemester(transaction, 1)
            do {
                try transaction.savepoint {
                    try Fixtures.insertSemester(transaction, 2)
                    throw Boom()
                }
                Issue.record("the savepoint did not rethrow")
            } catch is Boom {}
            try transaction.savepoint { try Fixtures.insertSemester(transaction, 3) }
        }
        let numbers = try store.run("SELECT number FROM semester ORDER BY number").compactMap { $0.int("number") }
        #expect(numbers == [1, 3])
    }

    @Test func readSeesOneStateAndRefusesWrites() throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertSemester($0) }
        #expect(try store.read { try $0.value("SELECT count(*) FROM semester") } == .integer(1))
        #expect(throws: StoreError.self) { try store.read { try $0.execute("DELETE FROM semester") } }
        #expect(try Fixtures.count(store, "semester") == 1)
        // Writes work again afterwards.
        try store.transaction { try $0.execute("DELETE FROM semester") }
        #expect(try Fixtures.count(store, "semester") == 0)
    }

    @Test func aTransactionHandleIsDeadOnceItsBodyEnds() throws {
        let store = try LocalStore.inMemory()
        nonisolated(unsafe) var escaped: StoreTransaction?
        try store.transaction { escaped = $0 }
        #expect(throws: StoreError.transactionEnded) { try escaped?.execute("SELECT 1") }
    }

    @Test func sharesAcrossTasksWithoutCorruptingRows() async throws {
        let store = try LocalStore.inMemory()
        try store.transaction { try Fixtures.insertSemester($0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<40 {
                group.addTask {
                    try store.transaction { transaction in
                        try Fixtures.insertCourse(transaction, 100 + number)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try Fixtures.count(store, "course") == 40)
    }

    // MARK: Files

    /// Read through a new URL: a URL keeps the resource values it has read, so one used to set a
    /// flag can report the old value.
    static func isExcludedFromBackup(_ item: URL) throws -> Bool? {
        try URL(fileURLWithPath: item.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    @Test func theFileIsProtectedAndKeptInTheBackup() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore.open(directory: directory)
        try store.transaction { try Fixtures.insertStudiedCourse($0) }
        let file = try #require(store.fileURL)

        for item in [directory, file] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication, "\(item.lastPathComponent)")
            #expect(try Self.isExcludedFromBackup(item) == false, "\(item.lastPathComponent)")
        }
    }

    @Test func openingPutsAFolderThatWasLeftOutOfTheBackupBack() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LocalStore.open(directory: directory)
        let file = try #require(first.fileURL)
        first.close()
        for item in [directory, file] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = item
            try url.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: item.path)
            // macOS can land the flag a moment after the call returns, which would undo the store's
            // write that follows; wait until it has, so the store really meets a left-out folder.
            for _ in 0..<500 where try Self.isExcludedFromBackup(item) != true { Thread.sleep(forTimeInterval: 0.002) }
            try #require(try Self.isExcludedFromBackup(item) == true)
        }

        let store = try LocalStore.open(directory: directory)
        for item in [directory, try #require(store.fileURL)] {
            #expect(try Self.isExcludedFromBackup(item) == false)
            let protection = try FileManager.default.attributesOfItem(atPath: item.path)[.protectionKey] as? FileProtectionType
            #expect(protection == .completeUntilFirstUserAuthentication)
        }
    }

    @Test func theBankIsOneFileWithNoSideFilesLeftBehind() throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore.open(directory: directory)
        try store.transaction { try Fixtures.insertStudiedCourse($0) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["bank.sqlite"])
    }
}
