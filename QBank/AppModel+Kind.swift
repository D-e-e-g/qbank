import QBankKit

extension AppModel {
    /// The client of an account of `kind`: the network for an account whose bank is on the server,
    /// and for a free account the bank on this phone, which answers the bank's requests itself while
    /// the account's requests (its session and color) still go to `network`. Only a free account is
    /// given a bank.
    static func client(
        for kind: AccountKind,
        configuration: APIConfiguration = .production,
        network: any HTTPTransport = URLSessionTransport(),
        bank: LocalBank? = nil,
        sessionStore: any SessionStore
    ) -> QBankClient {
        guard kind.bankIsOnPhone else {
            precondition(bank == nil, "Only a free account's bank is on this phone.")
            return QBankClient(configuration: configuration, transport: network, sessionStore: sessionStore)
        }
        guard let bank else { preconditionFailure("A free account needs its bank on this phone.") }
        return QBankClient(
            configuration: configuration,
            transport: BankRoutedTransport(bank: bank, account: network),
            sessionStore: sessionStore
        )
    }

    /// Whether Make questions and exam twins are on offer to this account at all, before the server
    /// says whether it may use them.
    var offersQuestionMaker: Bool {
        kind.makesQuestions
    }
}
