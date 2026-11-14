import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import QBankKit

@Suite("Contract: Review")
struct ReviewContractTests {
    @Test func reviewList() async throws {
        let fixture = try Fixture.load("review")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let list = try await client.review(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(list.filter == .all)
        #expect(list.counts == ReviewList.Counts(all: 7, missed: 2, partial: 4, guessed: 1))
        #expect(list.questions.count == 7)
        #expect(list.questions.allSatisfy { $0.folderName == "Week 1" && $0.folderID != nil })
    }

    @Test func filteredReviewList() async throws {
        let fixture = try Fixture.load("review-guessed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let list = try await client.review(courseID: courseID(of: fixture), filter: .guessed)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(list.filter == .guessed)
        #expect(list.questions.allSatisfy { $0.guessed })
    }

    @Test func reviewPractice() async throws {
        let fixture = try Fixture.load("review-practice")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let set = try await client.reviewPractice(courseID: courseID(of: fixture), filter: .missed)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(set.id == set.courseID)
        #expect(set.questions.count == 2)
    }

    @Test func reviewPracticeOneQuestion() async throws {
        let fixture = try Fixture.load("review-practice-one")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let questionID = try #require(fixture.request.query["question"])
        let set = try await client.reviewPractice(courseID: courseID(of: fixture), questionID: questionID)
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(set.questions.map(\.id) == [questionID])
    }

    @Test func clearNeedsConfirmation() async throws {
        let fixture = try Fixture.load("review-clear-unconfirmed")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let error = await #expect(throws: QBankError.self) {
            try await client.clearReview(courseID: courseID(of: fixture), confirmed: false)
        }
        #expect(error?.serverCode == .confirmationRequired)
        try expectRequest(transport.requests.first, matches: fixture)
    }

    @Test func clear() async throws {
        let fixture = try Fixture.load("review-clear")
        let transport = try FixtureTransport([fixture])
        let (client, _) = TestClient.make(transport)
        let cleared = try await client.clearReview(courseID: courseID(of: fixture))
        try expectRequest(transport.requests.first, matches: fixture)
        #expect(cleared == 7)
    }
}
