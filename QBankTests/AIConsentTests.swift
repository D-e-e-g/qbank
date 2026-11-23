import Foundation
import QBankKit
import Testing
@testable import QBank

/// The permission to share her material with Anthropic: kept on the phone, and asked for before
/// Make questions or exam twins send anything.
@MainActor
struct AIConsentTests {
    @Test func aNewPhoneHasNotAllowedIt() {
        #expect(!AIConsentStore(defaults: TestApp.freshDefaults()).isAllowed)
    }

    @Test func theChoiceIsRememberedByThePhone() {
        let defaults = TestApp.freshDefaults()
        let store = AIConsentStore(defaults: defaults)
        store.isAllowed = true
        #expect(AIConsentStore(defaults: defaults).isAllowed, "a relaunch finds it")
        store.isAllowed = false
        #expect(!AIConsentStore(defaults: defaults).isAllowed, "turning it off in Settings is remembered too")
    }

    @Test func theChoiceStaysWhenSheSignsOut() async {
        let (app, _) = TestApp.make(StubServer(["POST /api/sign-out": .ok(#"{"status":"signed-out"}"#)]), account: .student(), aiAllowed: true)
        await app.signOut()
        #expect(app.route == .signedOut)
        #expect(app.aiConsent.isAllowed, "a device setting, as Look is")
    }

    @Test func theScreenSaysWhatIsSentToWhomAndWhy() {
        let message = AIConsentWording.message
        for part in ["Anthropic", "Claude", "the notes you paste", "your photos", "a file you choose", "practice questions", "the QBank server", "to read your material and to write and check the questions", "Nothing is sent until you allow it", "Settings"] {
            #expect(message.contains(part), "says \(part)")
        }
        #expect(AIConsentWording.allow == "Allow")
        #expect(AIConsentWording.notNow == "Not now")
    }

    // MARK: Nothing is sent before Allow

    @Test func makeQuestionsSendsNothingBeforeAllow() async throws {
        let app = MakeQuestionsTests.app(aiAllowed: false)
        let hub = AddModel(app: app)
        await hub.load()
        let before = try #require(hub.status?.startedToday)
        let make = try await MakeQuestionsTests.pasted(app, status: hub.status)
        #expect(await make.start() == nil)
        #expect(make.problem == AIConsentWording.needed)
        await hub.load()
        #expect(hub.status?.startedToday == before, "the server never heard of a set")

        app.aiConsent.isAllowed = true
        #expect(await make.start() != nil)
        #expect(make.problem == nil)
    }

    @Test func photosAreNotSentBeforeAllowEither() async {
        let server = StubServer([
            "GET /api/semesters": .ok(Bodies.semesters()),
            "GET /api/me/place": .ok(Bodies.place("c1")),
            "GET /api/courses/c1": .ok(StudyBodies.course(id: "c1")),
            "POST /api/question-jobs": StubServer.Reply(status: 202, body: MakeQuestionsTests.job()),
        ])
        let (app, _) = TestApp.make(server, account: .student())
        let make = MakeModel(app: app, status: nil)
        await make.load()
        make.add(photo: Data([0xFF, 0xD8, 0xFF, 0x01]))
        #expect(await make.start() == nil)
        #expect(!server.calls.contains { $0.contains("question-jobs") }, "no request left the phone")
    }

    @Test func herNotesOnASetAlreadyBeingMadeWaitForAllow() async throws {
        let server = StubServer([
            "GET /api/question-jobs/job1": .ok(MakeQuestionsTests.job(status: "waiting", waitingFor: "samples")),
            "GET /api/question-jobs/job1/samples": .ok(MakeQuestionsTests.samples),
            "POST /api/question-jobs/job1/samples/revise": StubServer.Reply(status: 202, body: MakeQuestionsTests.job()),
            "POST /api/question-jobs/job1/samples/accept": StubServer.Reply(status: 202, body: MakeQuestionsTests.job()),
        ])
        // A set started before the permission was asked, or after she turned it off in Settings.
        let (app, _) = TestApp.make(server, account: .student())
        let model = JobModel(app: app, id: "job1")
        await model.load()
        let question = try #require(model.samples?.questions.last)
        model.mark(question, .change)
        model.notes[question.id] = "Ask about day 3."

        await model.reviseSamples()
        #expect(model.problem == AIConsentWording.needed)
        await model.acceptSamples()
        #expect(model.problem == AIConsentWording.needed)
        #expect(!server.calls.contains { $0.hasPrefix("POST") }, "her notes never left the phone")

        app.aiConsent.isAllowed = true
        await model.reviseSamples()
        #expect(model.problem == nil)
        #expect(server.calls.contains { $0.contains("samples/revise") })
    }

    @Test func checkedCopiesWaitForAllow() async throws {
        let app = MakeQuestionsTests.app(aiAllowed: false)
        let model = JobModel(app: app, id: MakeQuestionsTests.copyJob, pollInterval: .zero)
        await model.follow()
        #expect(model.copies != nil)
        await model.acceptCopies()
        #expect(model.problem == AIConsentWording.needed)
        #expect(model.job?.waitingFor == .copies, "still waiting for her check")

        app.aiConsent.isAllowed = true
        await model.acceptCopies()
        #expect(model.problem == nil)
        #expect(model.job?.waitingFor != .copies, "the server took her copies")
    }

    @Test func examTwinsSendNothingBeforeAllow() async throws {
        let app = MakeQuestionsTests.app(aiAllowed: false)
        let setup = try await TwinJobTests.week2(app)
        #expect(setup.canTwin)
        let before = try await app.client.twinJobs().count
        #expect(await setup.writeTwins() == nil)
        #expect(setup.twinProblem == AIConsentWording.needed)
        #expect(try await app.client.twinJobs().count == before, "no twin job was started")

        app.aiConsent.isAllowed = true
        #expect(await setup.writeTwins() != nil)
    }
}
