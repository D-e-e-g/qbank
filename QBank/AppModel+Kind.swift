import QBankKit

extension AppModel {
    /// Whether Make questions and exam twins are on offer to this account at all, before the server
    /// says whether it may use them.
    var offersQuestionMaker: Bool {
        kind.makesQuestions
    }
}
