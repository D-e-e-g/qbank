import Foundation
import QBankKit
import Testing
@testable import QBank

@MainActor
struct ExamModelTests {
    /// A model whose shuffles keep the stored order, whose ids count up, and whose clock and
    /// retries are under the test's control.
    static func model(
        _ server: StubServer,
        account: Account = .student(),
        clock: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping (Duration) async throws -> Void = { _ in }
    ) -> ExamModel {
        let (app, _) = TestApp.make(server, account: account)
        var next = 0
        return ExamModel(
            app: app, examID: "e1", clock: clock, sleep: sleep,
            makeLayout: { body in
                if case .single(let options) = body { return .options(order: Array(options.indices)) }
                return .plain
            },
            newAttemptID: {
                next += 1
                return "attempt-\(next)"
            }
        )
    }

    private func sentBody(_ server: StubServer) throws -> [String: Any] {
        let data = try #require(server.requests.last?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Lets a task the model started run to its end.
    private func settle(_ until: () -> Bool) async {
        for _ in 0..<300 where !until() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func opensOnTheFirstQuestionStillOpenWithTheServersTimeLeft() async throws {
        let server = StubServer(["GET /api/exams/e1": .ok(StudyBodies.exam(answered: ["e1-q0"]))])
        let model = Self.model(server)
        await model.load()
        #expect(model.phase == .running)
        #expect(model.items.map(\.submitted) == [true, false, false])
        #expect(model.index == 1)
        #expect(model.countText == "2 of 3")
        #expect(model.title == "Exam · Weeks 1-2")
        #expect(model.progress == 1.0 / 3)
        #expect(abs(model.secondsLeft - 600) < 1, "15 minutes from the start, 5 gone by the server's clock")
        #expect(!model.canSubmit, "nothing picked yet")
    }

    @Test func submitSendsTheAnswerWithTheExamAndMovesOn() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: StudyBodies.saved(question: "e1-q0", attempt: "attempt-1")),
        ])
        let model = Self.model(server)
        await model.load()
        model.update(.single(0))
        model.setGuessed(true)
        #expect(model.canSubmit)
        await model.submit()
        let body = try sentBody(server)
        #expect(body["studySessionId"] as? String == "e1")
        #expect(body["clientAttemptId"] as? String == "attempt-1")
        #expect(body["questionId"] as? String == "e1-q0")
        #expect(body["guessed"] as? Bool == true)
        #expect((body["response"] as? [String: Any])?["choice"] as? Int == 0)
        #expect(model.items[0].submitted)
        #expect(model.index == 1)
        #expect(model.submittedCount == 1)
        #expect(model.endMessage == "The 1 question you answered will be scored. Skipped and unreached questions score 0 and stay out of Review.")
    }

    @Test func skippedQuestionsComeBackAfterTheLastOneAndTheLastOpenOneFinishes() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: StudyBodies.saved(question: "e1-q1", attempt: "a")),
            "POST /api/exams/e1/finish": .ok(StudyBodies.exam(ended: "finished", result: StudyBodies.result())),
        ])
        let model = Self.model(server)
        await model.load()
        await model.skip()
        #expect(model.index == 1)
        #expect(model.items[0].skipped)
        #expect(model.skippedLeft == 0, "not back at the skipped ones yet")
        model.update(.single(1))
        await model.submit()
        #expect(model.index == 2)
        await model.skip()
        #expect(model.index == 0, "wraps back to the first skipped question")
        #expect(model.isReturning)
        #expect(model.wrappedTo == 0)
        #expect(model.skippedLeft == 2)
        #expect(!model.isLastPending)
        model.update(.single(0))
        await model.submit()
        #expect(model.index == 2)
        #expect(model.wrappedTo == nil)
        #expect(model.isLastPending, "its button says Finish exam")
        model.update(.single(0))
        await model.submit()
        await settle { model.phase == .ended }
        #expect(model.phase == .ended)
        #expect(server.calls.last == "POST /api/exams/e1/finish")
        #expect(try sentBody(server)["reason"] as? String == "finished")
        #expect(model.exam?.result?.fullyRight == 1)
    }

    @Test func struckChoicesStayWithTheQuestionWhileSheMovesAndAreNeverSent() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": StubServer.Reply(status: 201, body: StudyBodies.saved(question: "e1-q0", attempt: "attempt-1")),
        ])
        let model = Self.model(server)
        await model.load()
        model.update(.single(2))
        model.toggleStrike(2)
        model.toggleStrike(1)
        #expect(model.item?.struck == [1, 2])
        #expect(model.item?.draft == .single(nil), "striking her pick unpicks it")
        model.update(.single(1))
        #expect(model.item?.draft == .single(nil), "a struck choice cannot be picked")
        #expect(!model.canSubmit)
        await model.skip()
        #expect(model.item?.struck == [], "the next question starts with nothing struck")
        await model.skip()
        await model.skip()
        #expect(model.index == 0)
        #expect(model.item?.struck == [1, 2], "her strikes are still there when she comes back")
        model.toggleStrike(2)
        #expect(model.item?.struck == [1], "striking again restores it")
        model.update(.single(2))
        await model.submit()

        let sent = try #require(server.requests.last?.httpBody)
        #expect((try sentBody(server)["response"] as? [String: Any])?["choice"] as? Int == 2)
        #expect(!String(decoding: sent, as: UTF8.self).lowercased().contains("stru"), "strikes are never sent")
        #expect(model.index == 1)
        model.toggleStrike(0)
        #expect(model.items[0].struck == [1], "a submitted answer's strikes cannot change")
    }

    @Test func anAnswerTheServerAlreadyHasCountsAsSent() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": .error(409, "already_answered", "That question was already answered on this exam."),
        ])
        let model = Self.model(server)
        await model.load()
        model.update(.single(0))
        await model.submit()
        #expect(model.items[0].submitted)
        #expect(model.index == 1)
        #expect(model.problem == nil)
    }

    @Test func anExamThatEndedMeanwhileShowsItsResult() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": .error(409, "exam_finished", "This exam has ended. That answer was not saved."),
        ])
        let model = Self.model(server)
        await model.load()
        server["GET /api/exams/e1"] = .ok(StudyBodies.exam(ended: "timeout", result: StudyBodies.result()))
        model.update(.single(0))
        await model.submit()
        #expect(model.phase == .ended)
        #expect(model.exam?.endReason == .timeout)
    }

    @Test func aDroppedConnectionIsRetriedWithTheSameId() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": .offline,
        ])
        var waits: [Duration] = []
        var model: ExamModel?
        var sawWaiting = false
        model = Self.model(server, sleep: { delay in
            waits.append(delay)
            sawWaiting = sawWaiting || model?.isWaiting == true
            if waits.count == 3 {
                server["POST /api/attempts"] = StubServer.Reply(status: 201, body: StudyBodies.saved(question: "e1-q0", attempt: "attempt-1"))
            }
        })
        let exam = try #require(model)
        await exam.load()
        exam.update(.single(0))
        await exam.submit()
        #expect(waits == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(sawWaiting)
        #expect(!exam.isWaiting)
        let ids = server.requests.filter { $0.httpMethod == "POST" }.map { request in
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["clientAttemptId"] as? String
        }
        #expect(ids.count == 4)
        #expect(Set(ids) == ["attempt-1"])
        #expect(exam.index == 1)
    }

    @Test func endingEarlyScoresWhatSheAnswered() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/exams/e1/finish": .ok(StudyBodies.exam(ended: "left", result: StudyBodies.result())),
        ])
        let model = Self.model(server)
        await model.load()
        await model.end(.left)
        #expect(model.phase == .ended)
        #expect(try sentBody(server)["reason"] as? String == "left")
        #expect(model.exam?.endReason == .left)
    }

    @Test func anEndThatDoesNotGoThroughSaysSoAndKeepsTheExam() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/exams/e1/finish": .offline,
        ])
        let model = Self.model(server)
        await model.load()
        await model.end(.left)
        #expect(model.phase == .running)
        #expect(!model.isEnding)
        #expect(model.problem == "Could not end the exam. Check the connection and try again.")
    }

    @Test func aRefusedEndShowsTheServersWords() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/exams/e1/finish": .error(404, "exam_not_found", "That exam is not in the app."),
        ])
        let model = Self.model(server)
        await model.load()
        await model.end(.left)
        #expect(model.problem == "That exam is not in the app.")
    }

    @Test func anAnswerStillRetryingStopsWhenTheExamTurnsOutEnded() async throws {
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/attempts": .offline,
        ])
        var model: ExamModel?
        var retries = 0
        model = Self.model(server, sleep: { _ in
            retries += 1
            if retries == 1 {
                // She comes back to the app: the server has ended the exam meanwhile.
                server["GET /api/exams/e1"] = .ok(StudyBodies.exam(ended: "timeout", result: StudyBodies.result()))
                await model?.resync()
            }
        })
        let exam = try #require(model)
        await exam.load()
        exam.update(.single(0))
        await exam.submit()
        #expect(exam.phase == .ended)
        #expect(retries == 1, "no retry after the exam ended")
        #expect(!exam.isSaving)
        #expect(!exam.isWaiting)
    }

    @Test func theTimeRunningOutEndsTheExam() async throws {
        let start = ContinuousClock.now
        var elapsed = Duration.zero
        let server = StubServer([
            "GET /api/exams/e1": .ok(StudyBodies.exam()),
            "POST /api/exams/e1/finish": .ok(StudyBodies.exam(ended: "timeout", result: StudyBodies.result())),
        ])
        let model = Self.model(server, clock: { start.advanced(by: elapsed) })
        await model.load()
        elapsed = .seconds(599)
        model.tick()
        #expect(abs(model.secondsLeft - 1) < 0.01)
        #expect(model.phase == .running)
        elapsed = .seconds(601)
        model.tick()
        #expect(model.secondsLeft == 0)
        await settle { model.phase == .ended }
        #expect(model.phase == .ended)
        #expect(try sentBody(server)["reason"] as? String == "timeout")
    }

    @Test func comingBackChecksTheTimeWithTheServer() async throws {
        let server = StubServer(["GET /api/exams/e1": .ok(StudyBodies.exam())])
        let model = Self.model(server)
        await model.load()
        model.update(.single(1))
        server["GET /api/exams/e1"] = .ok(StudyBodies.exam(serverNow: "2026-10-12T00:14:00.000Z"))
        await model.resync()
        #expect(abs(model.secondsLeft - 60) < 1, "the server's clock wins")
        #expect(model.items[0].draft == .single(1), "her open answer stays")
        server["GET /api/exams/e1"] = .ok(StudyBodies.exam(ended: "timeout", result: StudyBodies.result()))
        await model.resync()
        #expect(model.phase == .ended)
    }

    @Test func anEndedExamOpensOnItsResult() async throws {
        let server = StubServer(["GET /api/exams/e1": .ok(StudyBodies.exam(ended: "finished", result: StudyBodies.result()))])
        let model = Self.model(server)
        await model.load()
        #expect(model.phase == .ended)
        #expect(model.items.isEmpty)
    }

    @Test func theOwnerSeesHerRunningExamAndNothingSheDoesIsSent() async throws {
        let server = StubServer(["GET /api/exams/e1": .ok(StudyBodies.exam())])
        let (app, _) = TestApp.make(server, account: .admin)
        let model = ExamModel(app: app, examID: "e1")
        await model.load()
        #expect(model.phase == .running)
        #expect(app.frozen.noteID != nil, "the runner opens with the note")
        let draft = try #require(model.item?.draft)
        model.setGuessed(true)
        #expect(model.item?.guessed == false)
        await model.submit()
        await model.skip()
        await model.end(.left)
        model.update(draft)
        #expect(model.phase == .running)
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
    }

    @Test func aFrozenExamWhoseTimeRanOutIsLeftForHerAppToEnd() async throws {
        let server = StubServer(["GET /api/exams/e1": .ok(StudyBodies.exam())])
        var now = ContinuousClock.now
        let (app, _) = TestApp.make(server, account: .admin)
        let model = ExamModel(app: app, examID: "e1", clock: { now })
        await model.load()
        now = now.advanced(by: .seconds(100_000))
        model.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.secondsLeft == 0)
        #expect(server.calls.allSatisfy { $0.hasPrefix("GET") })
    }

    @Test func aMissingExamIsSaidInTheServersWords() async throws {
        let server = StubServer(["GET /api/exams/e1": .error(404, "exam_not_found", "That exam is not in the app.")])
        let model = Self.model(server)
        await model.load()
        #expect(model.phase == .failed("That exam is not in the app."))
    }

    @Test func onlyConnectionTroubleIsRetried() {
        #expect(ExamModel.isTransient(.transport(.notConnectedToInternet)))
        #expect(ExamModel.isTransient(.transport(.timedOut)))
        #expect(ExamModel.isTransient(.server(ServerError(status: 502, code: .init(rawValue: "x"), message: ""))))
        #expect(ExamModel.isTransient(.unexpectedResponse(status: 503, detail: "proxy")))
        #expect(!ExamModel.isTransient(.server(ServerError(status: 409, code: .examFinished, message: ""))))
        #expect(!ExamModel.isTransient(.unexpectedResponse(status: 500, detail: "")))
        #expect(!ExamModel.isTransient(.cancelled))
        #expect(!ExamModel.isTransient(.notSignedIn))
    }

    @Test func examBankWrongIsWordedAsOnTheWeb() {
        #expect(ExamResultView.bankWrongText(1) == "1 exam-bank question you got wrong stays out of Review. Turn on Wrong questions only to take it again.")
        #expect(ExamResultView.bankWrongText(2) == "2 exam-bank questions you got wrong stay out of Review. Turn on Wrong questions only to take them again.")
    }
}
