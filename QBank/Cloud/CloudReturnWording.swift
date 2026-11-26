import Foundation
import QBankKit

/// The words of bringing the bank back from QBank Cloud once Cloud has ended: the hand-back's screen
/// and its row in Settings. A refusal from the server is said in the server's own sentence, which is
/// written to be shown as it is.
enum CloudReturnWording {
    static var bringBack: String { "Bring my bank back to this \(Device.model)" }
    static let stillInCloud = "QBank Cloud has ended, and your bank is still in it."
    static var stillInCloudProblem: String { "\(stillInCloud) Bring it back to this \(Device.model) from Settings." }

    // MARK: Bringing QBank's bank to a new phone

    static var bringHere: String { "Bring my bank to this \(Device.model)" }
    static var bringHereDetail: String { "QBank holds a bank for you. This \(Device.model) uses its own." }
    static let offeredTitle = "QBank has your bank"
    static var offeredBody: String {
        "QBank holds the bank you kept in QBank Cloud. Bring it to this \(Device.model) to study it here, without a connection. Nothing in QBank is changed or deleted."
    }
    static var offeredEarlierCopy: String {
        "The bank on this \(Device.model) stays on it, unchanged, as an earlier copy. Sets only in it are offered next, to add as new sets."
    }
    static var bringIt: String { "Bring it to this \(Device.model)" }
    static let notNow = "Not now"
    static var bringingTitle: String { "Bringing your bank to this \(Device.model)" }
    static var bringingNote: String { "Your bank is coming from QBank to this \(Device.model). Keep QBank open until it is done." }
    static var notBroughtTitle: String { "This \(Device.model) keeps its own bank" }

    // MARK: Returning

    static var returningTitle: String { "Bringing your bank back to this \(Device.model)" }
    static var returningNote: String {
        "QBank Cloud has ended, so your bank is coming back to this \(Device.model). Keep QBank open until it is done."
    }

    /// Each step, as the screen lists it.
    static func step(_ step: BankHandBack.Step) -> String {
        switch step {
        case .downloading: "Downloading your bank from QBank Cloud"
        case .writing: "Writing it to this \(Device.model)"
        case .checking: "Checking that everything arrived"
        }
    }

    // MARK: Returned

    static var returnedTitle: String { "Your bank is on this \(Device.model)" }
    static var returnedBody: String { "Everything from QBank Cloud is now on this \(Device.model), and it works without a connection." }
    static let cloudKept = "Nothing was deleted from QBank Cloud."

    /// The sets of the earlier copy offered once the bank is here.
    static func earlierCopyOffered(_ count: Int) -> String {
        "\(CloudAdoptWording.addSetsDetail(count, into: .phone)). Add \(count == 1 ? "it" : "them") to your bank from Settings."
    }

    // MARK: Failed

    static let failedTitle = "Your bank is still in QBank Cloud"
    static var unchanged: String { "Nothing on this \(Device.model) or in QBank Cloud was changed or deleted." }
    static var notInCloud: String { "There is no bank in QBank Cloud to bring back to this \(Device.model)." }

    /// Why a hand-back did not make this phone the authority. `bringsHere` when it was to bring QBank's
    /// bank in place of the one on this phone, which stays in use.
    static func problem(_ failure: BankHandBack.Failure, bringsHere: Bool = false) -> String {
        switch failure {
        case .notStarted:
            "This \(Device.model) could not note that your bank was coming back, so nothing started."
        case .alreadyOnPhone:
            "Your bank is on this \(Device.model) already."
        case .notDownloaded(let error):
            notDownloaded(error)
        case .notWritten:
            "Your bank did not arrive whole, so this \(Device.model) did not use it."
        case .countsDiffer(let differences):
            "This \(Device.model) did not get the same number of \(CloudMoveWording.list(differences.map { CloudMoveWording.name(of: $0.table) })) as QBank Cloud holds, so it did not switch."
        case .answersNotKept:
            "The answers waiting to be sent could not be kept in the bank on this \(Device.model), so it did not switch."
        case .notCompared:
            "The bank on this \(Device.model) could not be read to find the sets only it has, so it did not switch."
        case .switchNotRecorded:
            "Your whole bank arrived, but this \(Device.model) could not note the switch, so it keeps using \(bringsHere ? "its own bank" : "QBank Cloud's bank")."
        }
    }

    /// Whether trying again may end differently: always, but for a bank that is on this phone already.
    /// Nothing is changed by a try, so another one is safe.
    static func canRetry(_ failure: BankHandBack.Failure) -> Bool {
        failure != .alreadyOnPhone
    }

    /// Why the download did not arrive whole.
    static func notDownloaded(_ error: QBankError) -> String {
        switch error {
        case .server(let refusal) where refusal.status < 500:
            return refusal.message
        case .server, .unexpectedResponse(500..., _):
            return "QBank Cloud could not send your bank right now. Try again in a moment."
        case .unexpectedResponse:
            return "QBank Cloud's answer could not be read, so your bank was not used."
        case .transport(.notConnectedToInternet), .transport(.dataNotAllowed), .transport(.internationalRoamingOff):
            return "No connection, so your bank could not be downloaded. Check Wi-Fi or cellular data and try again."
        case .transport(.timedOut):
            return "QBank Cloud did not answer in time, so your bank was not downloaded."
        case .transport:
            return "The connection dropped before your whole bank arrived."
        case .cancelled:
            return "The download stopped before your whole bank arrived."
        case .notSignedIn, .storage, .invalidRequest:
            return "Your bank could not be downloaded. Try again."
        }
    }
}
