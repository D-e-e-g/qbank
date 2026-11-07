import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// The admin's look at a user account, against recordings of the server's real routes: the accounts
/// it may look at, and the refusal every write to them gets.
@Suite("Contract: the admin's frozen view")
struct AdminContractTests {
    @Test func theListSaysWhichAccountIsOnScreen() async throws {
        let fixture = try Fixture.load("admin-students")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let list = try await client.students()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(list.students.map(\.email) == ["student@example.com", "second.user@example.com"])
        #expect(list.viewing?.email == "student@example.com", "until it picks one, the admin looks at the oldest")
    }

    @Test func withNoUserAccountNothingIsOnScreen() async throws {
        let fixture = try Fixture.load("admin-students-none")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let list = try await client.students()
        #expect(list.students.isEmpty)
        #expect(list.viewing == nil)
    }

    @Test func aWriteIsRefusedWithItsOwnCode() throws {
        let fixture = try Fixture.load("admin-read-only")
        #expect(fixture.response.status == 403)
        #expect(fixture.response.body["error"]?.stringValue == ServerError.Code.adminReadOnly.rawValue)
        let error = QBankError.server(ServerError(status: 403, code: .adminReadOnly, message: ""))
        #expect(error.isAdminReadOnly)
        #expect(QBankError.server(ServerError(status: 403, code: .adminCannotRecordAnswer, message: "")).isAdminReadOnly)
        #expect(QBankError.server(ServerError(status: 403, code: .adminCannotDeleteExam, message: "")).isAdminReadOnly)
        #expect(!QBankError.server(ServerError(status: 403, code: .adminCannotDeleteAccount, message: "")).isAdminReadOnly)
    }
}
