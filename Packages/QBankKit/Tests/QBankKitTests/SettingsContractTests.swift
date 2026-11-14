import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Contract: settings")
struct SettingsContractTests {
    @Test func emptyStudyPlace() async throws {
        let transport = try FixtureTransport("place-empty")
        let (client, _) = TestClient.make(transport)
        #expect(try await client.studyPlace() == nil)
        try expectRequest(transport.requests.first, matches: Fixture.load("place-empty"))
    }

    @Test func studyPlace() async throws {
        let fixture = try Fixture.load("place")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let place = try await client.studyPlace()
        #expect(place == fixture.response.body["courseId"]?.stringValue)
        #expect(place != nil)
    }

    @Test func setStudyPlace() async throws {
        let fixture = try Fixture.load("place-put")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let courseID = try #require(fixture.request.body?["courseId"]?.stringValue)
        try await client.setStudyPlace(courseID: courseID)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func exportIsTheFileAsSent() async throws {
        let fixture = try Fixture.load("export")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let data = try await client.exportProgress()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == fixture.response.body)
    }
}
