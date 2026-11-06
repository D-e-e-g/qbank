import Foundation
import QBankKit
import Testing
@testable import QBank

private func userCode(_ request: URLRequest?) throws -> String? {
    let body = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])["userCode"] as? String
}

/// Settings' Connect an agent against invented server answers: the code, her answer, the pickup,
/// her keys and Revoke, and what she is told when the server refuses.
@MainActor
struct ConnectAgentModelTests {
    private static let notFound = StubServer.Reply.error(404, "pairing_not_found", "No agent is waiting under that code. Codes last 10 minutes: ask the agent for its new one.")
    private static let macKey = Bodies.agentKey(id: "k1", name: "My MacBook agent")

    private func make(_ server: StubServer, account: Account = .student(), now: @escaping () -> Date = Date.init) -> (ConnectAgentModel, AppModel) {
        let (app, _) = TestApp.make(server, account: account)
        return (ConnectAgentModel(app: app, now: now, pickupInterval: .zero), app)
    }

    // MARK: The code

    /// The code goes trimmed and in capitals, as she typed it otherwise: the server takes it with
    /// or without its dash.
    @Test(arguments: [("  kxpd-mwrt \n", "KXPD-MWRT"), ("kxpdmwrt", "KXPDMWRT")])
    func theCodeIsLookedUpTrimmedAndInCapitals(typed: String, sent: String) async throws {
        let server = StubServer(["POST /api/agent-pairings/lookup": .ok(Bodies.agentPairing())])
        let (model, _) = make(server)
        model.code = typed
        await model.lookUp()
        #expect(try userCode(server.requests.last) == sent)
        guard case .found(let code, let pairing) = model.stage else {
            Issue.record("no agent shown: \(model.stage)")
            return
        }
        #expect(code == sent)
        #expect(pairing.name == "Study laptop agent")
        #expect(model.problem == nil)
        #expect(model.isBusy == false)
    }

    @Test func noCodeAsksForOneAndSendsNothing() async {
        let server = StubServer()
        let (model, _) = make(server)
        model.code = "   "
        await model.lookUp()
        #expect(model.problem == "Enter the code your agent shows you.")
        #expect(server.calls.isEmpty)
        #expect(model.stage == .enter)
    }

    @Test func aCodeThatMatchesNothingSaysWhyInTheServersWords() async {
        let (model, _) = make(StubServer(["POST /api/agent-pairings/lookup": Self.notFound]))
        model.code = "zzzz-zzzz"
        await model.lookUp()
        #expect(model.stage == .enter)
        #expect(model.problem == "No agent is waiting under that code. Codes last 10 minutes: ask the agent for its new one.")
        #expect(model.code == "zzzz-zzzz", "her code stays, to fix")

        model.code = "zzzz-zzzb"
        model.codeChanged()
        #expect(model.problem == nil, "a new code drops what was said about the last")
    }

    /// The fifth code that matches nothing locks her answers: Continue waits out the time the server
    /// gives, and the line saying how long stays while she types.
    @Test func theLockHoldsContinueUntilItsTimeHasPassed() async {
        let server = StubServer([
            "POST /api/agent-pairings/lookup": StubServer.Reply(
                status: 429, body: #"{"error":"too_many_attempts","message":"Too many tries. Try again in 15 minutes.","retryAfterSeconds":900}"#
            ),
        ])
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (model, _) = make(server, now: { clock.value })
        model.code = "GGGG-GGGG"
        await model.lookUp()
        #expect(model.problem == "Too many tries. Try again in 15 minutes.")
        #expect(model.lockedUntil == clock.value.addingTimeInterval(900))
        #expect(model.canContinue == false)

        model.code = "KXPD-MWRT"
        model.codeChanged()
        await model.lookUp()
        #expect(server.calls.count == 1, "nothing is sent while locked")
        #expect(model.problem == "Too many tries. Try again in 15 minutes.")

        clock.value = clock.value.addingTimeInterval(899)
        model.lockEnded()
        #expect(model.canContinue == false)
        clock.value = clock.value.addingTimeInterval(1)
        model.lockEnded()
        #expect(model.canContinue)
        #expect(model.problem == nil)
    }

    // MARK: Her answer

    /// After an approval the agent picks its key up on its next poll: the list is read again until
    /// a key that was not there shows.
    @Test func anApprovalWatchesForTheKeyUntilTheAgentPicksItUp() async throws {
        let server = StubServer([
            "GET /api/agent-keys": .ok(Bodies.agentKeys([Self.macKey])),
            "POST /api/agent-pairings/lookup": .ok(Bodies.agentPairing()),
            "POST /api/agent-pairings/approve": .ok(Bodies.agentPairing(status: "approved")),
        ])
        let (model, _) = make(server)
        await model.load()
        model.code = "KXPD-MWRT"
        await model.lookUp()
        await model.answer(approve: true)
        #expect(model.stage == .answered(approved: true, name: "Study laptop agent"))
        #expect(model.code == "", "the field is empty for the next code")
        #expect(try userCode(server.requests.last) == "KXPD-MWRT")
        #expect(model.watching == ["k1"])

        let picked = Bodies.agentKeys([Bodies.agentKey(id: "k2", name: "Study laptop agent"), Self.macKey])
        server.script("GET /api/agent-keys", [.ok(Bodies.agentKeys([Self.macKey])), .offline, .ok(picked)])
        await model.watchForPickup()
        #expect(model.keys?.map(\.id) == ["k2", "k1"])
        #expect(model.watching == nil)
        #expect(server.calls.filter { $0 == "GET /api/agent-keys" }.count == 4, "the first load and three polls, one without signal")
    }

    @Test func thePollsStopAfterTwoMinutesWithoutTheKey() async {
        let server = StubServer([
            "GET /api/agent-keys": .ok(Bodies.agentKeys([])),
            "POST /api/agent-pairings/lookup": .ok(Bodies.agentPairing()),
            "POST /api/agent-pairings/approve": .ok(Bodies.agentPairing(status: "approved")),
        ])
        let (model, _) = make(server)
        model.code = "KXPD-MWRT"
        await model.lookUp()
        await model.answer(approve: true)
        #expect(model.watching == [], "watching from no keys, the list not loaded yet")
        await model.watchForPickup()
        #expect(model.watching == nil)
        #expect(server.calls.filter { $0 == "GET /api/agent-keys" }.count == ConnectAgentModel.pickupPolls)
        #expect(ConnectAgentModel.pickupPolls == 30)
    }

    /// Approved before the keys loaded: nothing earlier to compare, so an already listed key is not
    /// taken for the new one and the polls go on.
    @Test func anApprovalBeforeTheKeysLoadedKeepsPollingPastTheFirstAnswer() async {
        let server = StubServer([
            "GET /api/agent-keys": .ok(Bodies.agentKeys([Self.macKey])),
            "POST /api/agent-pairings/lookup": .ok(Bodies.agentPairing()),
            "POST /api/agent-pairings/approve": .ok(Bodies.agentPairing(status: "approved")),
        ])
        let (model, _) = make(server)
        model.code = "KXPD-MWRT"
        await model.lookUp()
        await model.answer(approve: true)
        #expect(model.keys == nil)
        await model.watchForPickup()
        #expect(model.watching == nil)
        #expect(server.calls.filter { $0 == "GET /api/agent-keys" }.count == ConnectAgentModel.pickupPolls)
    }

    @Test func aDenialMakesNoKeyAndWatchesForNone() async throws {
        let server = StubServer([
            "POST /api/agent-pairings/lookup": .ok(Bodies.agentPairing(name: "Library desktop agent", scopes: ["import", "manage"])),
            "POST /api/agent-pairings/deny": .ok(Bodies.agentPairing(name: "Library desktop agent", scopes: ["import", "manage"], status: "denied")),
        ])
        let (model, _) = make(server)
        model.code = "HZNB-QLVS"
        await model.lookUp()
        await model.answer(approve: false)
        #expect(model.stage == .answered(approved: false, name: "Library desktop agent"))
        #expect(server.calls.last == "POST /api/agent-pairings/deny")
        #expect(try userCode(server.requests.last) == "HZNB-QLVS")
        #expect(model.watching == nil)
    }

    /// Run out or answered elsewhere meanwhile: back to the code, with the server's reason.
    @Test func anAnswerTheServerRefusesGoesBackToTheCode() async {
        let server = StubServer([
            "POST /api/agent-pairings/lookup": .ok(Bodies.agentPairing()),
            "POST /api/agent-pairings/approve": Self.notFound,
        ])
        let (model, _) = make(server)
        model.code = "KXPD-MWRT"
        await model.lookUp()
        await model.answer(approve: true)
        #expect(model.stage == .enter)
        #expect(model.problem == "No agent is waiting under that code. Codes last 10 minutes: ask the agent for its new one.")
        #expect(model.code == "KXPD-MWRT")
        #expect(model.watching == nil)
    }

    // MARK: Her keys

    @Test func revokingTurnsTheRowRevokedInPlace() async throws {
        let revoked = Bodies.agentKey(id: "k1", name: "My MacBook agent", revokedAt: "2026-10-26T10:00:00.000Z")
        let server = StubServer([
            "GET /api/agent-keys": .ok(Bodies.agentKeys([Bodies.agentKey(id: "k2", name: "Study laptop agent"), Self.macKey])),
            "POST /api/agent-keys/k1/revoke": .ok(revoked),
        ])
        let (model, _) = make(server)
        await model.load()
        await model.revoke(try #require(model.keys?.last))
        #expect(model.keys?.map(\.id) == ["k2", "k1"], "it stays in its place")
        #expect(model.keys?.map(\.isRevoked) == [false, true])
        #expect(model.revoked == "Revoked My MacBook agent. It stopped working just now.")
        #expect(model.revokingID == nil)
        #expect(server.requests.last?.httpBody == nil, "nothing but the key's id")
    }

    @Test func aRevokeTheServerRefusesKeepsTheRowAndSaysWhy() async throws {
        let server = StubServer([
            "GET /api/agent-keys": .ok(Bodies.agentKeys([Self.macKey])),
            "POST /api/agent-keys/k1/revoke": .error(404, "agent_key_not_found", "You have no agent key with that id."),
        ])
        let (model, _) = make(server)
        await model.load()
        await model.revoke(try #require(model.keys?.first))
        #expect(model.keys?.first?.isRevoked == false)
        #expect(model.revokeProblem == "You have no agent key with that id.")
        #expect(model.revoked == nil)
    }

    @Test func aFirstLoadWithoutSignalSaysSoAndALaterOneKeepsTheList() async {
        let server = StubServer(["GET /api/agent-keys": .offline])
        let (model, _) = make(server)
        await model.load()
        #expect(model.keys == nil)
        #expect(model.loadProblem == "No connection. Check Wi-Fi or cellular data and try again.")

        server["GET /api/agent-keys"] = .ok(Bodies.agentKeys([Self.macKey]))
        await model.load()
        #expect(model.loadProblem == nil)
        server["GET /api/agent-keys"] = .offline
        await model.load()
        #expect(model.keys?.map(\.id) == ["k1"])
        #expect(model.loadProblem == nil)
    }

    // MARK: The session

    @Test func anEndedSessionSignsOut() async {
        let (model, app) = make(StubServer(["POST /api/agent-pairings/lookup": .error(401, "unauthenticated", "Sign in to continue.")]))
        model.code = "KXPD-MWRT"
        await model.lookUp()
        #expect(app.route == .signedOut)
        #expect(model.problem == nil)
    }

    @Test func aTemporaryPasswordIsReplacedFirst() async {
        let (model, app) = make(StubServer(["GET /api/agent-keys": .error(403, "must_change_password", "Choose a new password to continue.")]))
        await model.load()
        #expect(app.route == .choosingPassword(.student()))
        #expect(model.loadProblem == nil)
    }

    /// An agent key reaches only its own account's content and the admin account has none, so the
    /// words promise nothing, whatever the server describes for a user account's key.
    @Test func theAdminIsToldItsKeyReachesNothing() throws {
        let pairing = try QBankJSON.decoder.decode(AgentPairing.self, from: Data(Bodies.agentPairing(scopes: ["manage"]).utf8))
        let (student, _) = make(StubServer())
        let (admin, _) = make(StubServer(), account: .admin)
        #expect(AgentWording.pairingScopes(pairing, admin: student.isAdmin).map(\.title) == ["Add, change, and delete your content"])
        #expect(AgentWording.pairingScopes(pairing, admin: admin.isAdmin).map(\.title) == ["Add, change, and delete content"])
        #expect(AgentWording.pairingScopes(pairing, admin: admin.isAdmin).map(\.detail) == [AgentWording.adminKeyReach])
    }
}
