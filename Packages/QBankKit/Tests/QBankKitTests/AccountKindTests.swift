import Testing

@testable import QBankKit

/// What each kind of account can do. The invited account keeps everything it has today.
@Suite struct AccountKindTests {
    @Test func anInvitedAccountKeepsEverythingItHasToday() {
        let kind = AccountKind.invited
        #expect(!kind.bankIsOnPhone)
        #expect(kind.hasPassword)
        #expect(kind.connectsAgents)
        #expect(kind.makesQuestions)
        #expect(kind.savesForOffline)
        #expect(kind.deletesWithPassword)
    }

    @Test func aStoreAccountHasNoPasswordNoAgentAndNoQuestionMakerButItsBankIsOnTheServer() {
        let kind = AccountKind.store
        #expect(!kind.bankIsOnPhone)
        #expect(!kind.hasPassword)
        #expect(!kind.connectsAgents)
        #expect(!kind.makesQuestions)
        #expect(kind.savesForOffline, "a Cloud bank is on the server, so it is saved for offline as today")
        #expect(!kind.deletesWithPassword)
    }

    @Test func aFreeAccountHasItsBankOnThePhoneAndNothingToSaveForOffline() {
        let kind = AccountKind.free
        #expect(kind.bankIsOnPhone)
        #expect(!kind.hasPassword)
        #expect(!kind.connectsAgents)
        #expect(!kind.makesQuestions)
        #expect(!kind.savesForOffline, "the whole bank is already on the phone")
        #expect(!kind.deletesWithPassword)
    }

    @Test func onlyAFreeAccountsBankIsOnThePhone() {
        #expect(AccountKind.allCases.filter(\.bankIsOnPhone) == [.free])
    }
}
