import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

/// Connect an agent against recordings of the server's real routes, signed in with a bearer token
/// as the app is: looking up the code her agent shows, approving or denying it, her keys, and
/// revoking one. The app never calls the agent's own routes, so no recording holds a key.
@Suite("Contract: connecting an agent")
struct AgentContractTests {
    // MARK: The code

    /// The code goes as she typed it, without its dash: the server finds the agent anyway.
    @Test func aLookupSendsTheCodeAndShowsWhoAsksForWhat() async throws {
        let fixture = try Fixture.load("agent-pairing-lookup")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let code = try #require(fixture.request.body?["userCode"]?.stringValue)
        #expect(!code.contains("-"))
        let pairing = try await client.agentPairing(code: code)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(pairing.name == "My MacBook agent")
        #expect(pairing.scopes == [.import, .read])
        #expect(pairing.scopeTexts.map(\.scope) == pairing.scopes)
        #expect(pairing.scopeTexts.first?.text == "Import question sets into your courses and topics, and see your courses, folders and sets to do it.")
        #expect(pairing.status == .pending)
        #expect(abs(pairing.expiresAt.timeIntervalSince(pairing.createdAt) - 600) < 0.001, "a code lasts 10 minutes")
    }

    @Test func anAgentThatAsksToManageSaysSo() async throws {
        let fixture = try Fixture.load("agent-pairing-lookup-manage")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let pairing = try await client.agentPairing(code: try #require(fixture.request.body?["userCode"]?.stringValue))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(pairing.name == "Study laptop agent")
        #expect(pairing.scopes == [.import, .manage])
        let manage = try #require(pairing.scopeTexts.first { $0.scope == .manage })
        #expect(manage.text.contains("Recently deleted"))
    }

    @Test(arguments: [
        ("agent-pairing-approve", AgentPairing.Status.approved),
        ("agent-pairing-deny", AgentPairing.Status.denied),
    ])
    func anAnswerSendsTheCodeAndSaysHowItWent(name: String, status: AgentPairing.Status) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let code = try #require(fixture.request.body?["userCode"]?.stringValue)
        let pairing =
            status == .approved
            ? try await client.approveAgentPairing(code: code)
            : try await client.denyAgentPairing(code: code)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(pairing.status == status)
        #expect(fixture.request.body == .object(["userCode": .string(code)]), "nothing else is sent")
    }

    /// A code nobody waits under, one answered already, or a temporary password: the server's sentence
    /// to show, and she stays signed in.
    @Test(arguments: [
        ("agent-pairing-lookup-not-found", ServerError.Code.pairingNotFound),
        ("agent-pairing-approve-answered", ServerError.Code.pairingNotFound),
        ("agent-pairing-lookup-temporary-password", ServerError.Code.mustChangePassword),
    ])
    func aRefusalSaysWhy(name: String, code: ServerError.Code) async throws {
        let fixture = try Fixture.load(name)
        let transport = try FixtureTransport([fixture])
        let (client, store) = TestClient.make(transport)
        let userCode = try #require(fixture.request.body?["userCode"]?.stringValue)
        let error = await #expect(throws: QBankError.self) {
            if fixture.request.path.hasSuffix("/approve") {
                try await client.approveAgentPairing(code: userCode)
            } else {
                _ = try await client.agentPairing(code: userCode)
            }
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: code)
        #expect(error?.needsSignIn == false)
        #expect(try store.load()?.token == "synthetic-session-token")
    }

    @Test func aCodeThatMatchesNothingSaysCodesRunOut() throws {
        let fixture = try Fixture.load("agent-pairing-lookup-not-found")
        #expect(fixture.response.body["message"]?.stringValue == "No agent is waiting under that code. Codes last 10 minutes: ask the agent for its new one.")
    }

    /// The fifth code that matches nothing locks her answers, and says for how long.
    @Test func theFifthMissLocksForAWhile() async throws {
        let fixture = try Fixture.load("agent-pairing-lookup-locked")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            _ = try await client.agentPairing(code: try #require(fixture.request.body?["userCode"]?.stringValue))
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .tooManyAttempts)
        guard case .server(let server)? = error else { return }
        #expect(server.retryAfterSeconds == 900)
        #expect(fixture.response.headers["retry-after"] == "900")
    }

    // MARK: Her keys

    @Test func noKeysYet() async throws {
        let fixture = try Fixture.load("agent-keys-empty")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        #expect(try await client.agentKeys().isEmpty)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    /// Newest first, revoked ones included, each with when it was made and last used.
    @Test func herKeysAreListedNewestFirst() async throws {
        let fixture = try Fixture.load("agent-keys")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let keys = try await client.agentKeys()
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(keys.map(\.name) == ["Old phone agent", "Study laptop agent", "My MacBook agent"])
        #expect(keys.map(\.createdAt) == keys.map(\.createdAt).sorted(by: >))
        #expect(keys.map(\.isRevoked) == [true, false, false])
        #expect(keys[1].scopes == [.import, .manage])
        #expect(keys[1].lastUsedAt == nil)
        #expect(keys[2].scopes == [.import, .read])
        #expect(keys[2].lastUsedAt != nil, "it imported a set")
    }

    /// A revoke sends nothing but the key's id, and answers the key, revoked.
    @Test func aRevokeAnswersTheKeyRevoked() async throws {
        let fixture = try Fixture.load("agent-key-revoke")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = fixture.request.path.split(separator: "/")[2]
        let key = try await client.revokeAgentKey(id: String(id))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(key.id == String(id))
        #expect(key.name == "Old phone agent")
        #expect(key.isRevoked)
        let listed = try Fixture.load("agent-keys").decodeBody(AgentKeysResponse.self).keys
        #expect(listed.first == key, "the list shows it revoked, in its place")
    }

    @Test func aKeySheDoesNotHaveIsRefused() async throws {
        let fixture = try Fixture.load("agent-key-revoke-not-found")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let id = fixture.request.path.split(separator: "/")[2]
        let error = await #expect(throws: QBankError.self) {
            try await client.revokeAgentKey(id: String(id))
        }
        try expectRequest(transport.requests.first, matches: fixture)
        try MakeQuestionsContractTests.expect(error, is: fixture, code: .agentKeyNotFound)
    }

    /// A scope added after this version still decodes, by its name.
    @Test func aScopeAddedLaterDecodes() throws {
        let body = #"{"id":"k1","name":"Invented agent","scopes":["import","export"],"createdAt":"2026-10-25T10:00:00.000Z","lastUsedAt":null,"revokedAt":null}"#
        let key = try QBankJSON.decoder.decode(AgentKey.self, from: Data(body.utf8))
        #expect(key.scopes == [.import, AgentScope(rawValue: "export")])
    }

    // MARK: What an agent imported

    /// A set her agent imported names its key; hers names none. The key is the one she sees listed.
    @Test func aSetHerAgentImportedSaysSo() async throws {
        let fixture = try Fixture.load("course-imported-by-agent")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let course = try await client.course(id: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        let sets = try #require(course.folders.first { $0.name == "Week 1" }).sets
        #expect(sets.first { $0.title == "Week 1 - Set 1: Her own set" }?.importedByAgent == nil)
        let agent = try #require(sets.first { $0.title == "Week 1 - Set 2: From her agent" }?.importedByAgent)
        #expect(agent.name == "My MacBook agent")
        let keys = try Fixture.load("agent-keys").decodeBody(AgentKeysResponse.self).keys
        #expect(keys.first { $0.name == "My MacBook agent" }?.id == agent.id)
    }

    /// A set from a recording or a saved copy from before agent keys names no agent.
    @Test func aSetFromBeforeAgentKeysNamesNone() throws {
        let course = try Fixture.load("course").decodeBody(CourseDetail.self)
        let sets = course.folders.flatMap(\.sets)
        #expect(!sets.isEmpty)
        #expect(sets.allSatisfy { $0.importedByAgent == nil })
    }

    /// No recording holds an agent key: the app never calls the routes that hand one out.
    @Test func noRecordingHoldsAnAgentKey() throws {
        for fixture in try Fixture.all() {
            let text = String(decoding: try JSONEncoder().encode(fixture.response.body), as: UTF8.self)
            #expect(!text.contains("qbk_"), "\(fixture.name)")
            #expect(fixture.request.authorization?.contains("qbk_") != true, "\(fixture.name)")
        }
    }
}
