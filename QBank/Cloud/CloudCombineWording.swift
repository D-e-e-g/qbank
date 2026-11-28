import Foundation
import QBankKit

/// The words of combining the bank on this phone with the one QBank holds: the combine's screen and
/// its row in Settings, as the release plan approved them. A refusal from the server is said in the
/// server's own sentence, which is written to be shown as it is.
enum CloudCombineWording {
    // MARK: Settings

    static let combineUp = "Combine my bank with QBank Cloud"
    static var combineUpDetail: String { "Your bank is still on this \(Device.model)." }
    static var combineDown: String { "Bring my bank to this \(Device.model)" }
    static var combineDownDetail: String { "QBank holds a bank for you that is not on this \(Device.model) yet." }

    // MARK: While it runs

    static var lead: String { "With QBank Cloud on, QBank keeps one bank for you. What is only on this \(Device.model) is added to it. Nothing is removed." }
    static var answersAdded: String { "Your answers from this \(Device.model) are added too." }
    static var safetyCopy: String { "The bank on this \(Device.model) stays on it, unchanged, as a safety copy." }
    static let combiningTitle = "Combining your banks"
    static let keepOpen = "Keep QBank open. Your bank can't change until this ends."

    /// Each step, as the screen lists it.
    static func step(_ step: CloudCombineModel.Step) -> String {
        switch step {
        case .reading: "Reading your bank in QBank Cloud"
        case .combining: "Combining it with the bank on this \(Device.model)"
        case .sending: "Sending what QBank Cloud does not have"
        case .checking: "Checking that everything is there"
        }
    }

    // MARK: Done

    static let combinedTitle = "Your banks are combined"
    static var combinedUpBody: String { "QBank Cloud now holds everything from this \(Device.model) and everything it already had. Nothing was removed." }
    static var combinedDownBody: String {
        "Everything QBank held for you is on this \(Device.model), together with what was already here. Nothing in QBank was changed or deleted."
    }
    static let newerKept = "Where something was changed in both places, the newer change was kept."
    /// Where a change would have given two items one name (WIN-14), and the name QBank held stayed.
    static let nameKept = "Where a new name was already taken, the name QBank had was kept."

    /// "Added from this iPhone: 2 sets, 41 answers".
    static func added(sets: Int, answers: Int) -> String {
        "Added from this \(Device.model): \(count(sets, "set", "sets")), \(count(answers, "answer", "answers"))"
    }

    private static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number.formatted()) \(number == 1 ? one : many)"
    }

    // MARK: Failed

    static let failedTitle = "Your banks were not combined"
    static var unchanged: String { "Nothing on this \(Device.model) or in QBank Cloud was removed. You can keep using the bank on this \(Device.model)." }
    static let paused = "Combining banks is paused in QBank for now. Try again later from Settings."
    static var notOnThisPhone: String { "There is no bank on this \(Device.model) to combine." }
    static var statusUnread: String { "QBank could not say what it holds for you, so nothing was combined. Try again in a moment." }

    /// Why a combine up did not switch the bank to QBank Cloud.
    static func problem(_ failure: BankCombineUp.Failure) -> String {
        switch failure {
        case .notStarted:
            "This \(Device.model) could not note that a combine was starting, so it did not start."
        case .alreadyInCloud:
            CloudMoveWording.inCloud
        case .notDownloaded(let error):
            CloudReturnWording.notDownloaded(error)
        case .notCombined:
            notCombined
        case .notStored(let error):
            CloudMoveWording.notStored(error)
        case .countsDiffer(let differences):
            "QBank Cloud does not hold the same number of \(CloudMoveWording.list(differences.map { CloudMoveWording.name(of: $0.table) })) as the combined bank, so QBank keeps using the bank on this \(Device.model)."
        case .switchNotRecorded:
            "QBank Cloud holds the combined bank, but this \(Device.model) could not note the switch, so it keeps using the bank here."
        }
    }

    /// Why a combine down did not switch to the combined bank.
    static func problem(_ failure: BankHandBack.Failure) -> String {
        switch failure {
        case .notStarted:
            "This \(Device.model) could not note that a combine was starting, so it did not start."
        case .alreadyOnPhone, .answersNotKept:
            notCombined
        case .notDownloaded(let error):
            CloudReturnWording.notDownloaded(error)
        case .notWritten, .notCombined:
            notCombined
        case .countsDiffer(let differences):
            "The combined bank on this \(Device.model) does not hold the same number of \(CloudMoveWording.list(differences.map { CloudMoveWording.name(of: $0.table) })) as it should, so it did not switch."
        case .switchNotRecorded:
            "Your banks were combined, but this \(Device.model) could not note the switch, so it keeps using the bank it had."
        }
    }

    private static var notCombined: String { "The two banks could not be combined, so this \(Device.model) did not switch." }

    /// Whether trying a combine up again may end differently. Not for a bank already in QBank Cloud,
    /// nor once QBank Cloud holds the combined bank and the counts or the switch failed: a later try
    /// from Settings combines again.
    static func canRetry(_ failure: BankCombineUp.Failure) -> Bool {
        switch failure {
        case .notStarted, .notDownloaded, .notCombined: true
        case .alreadyInCloud, .countsDiffer, .switchNotRecorded: false
        case .notStored(.unexpectedResponse): true
        case .notStored(let error): error.isTemporary || error.serverCode == .bankChanged
        }
    }

    /// Whether trying a combine down again may end differently. Nothing is changed by a try, so another
    /// one is safe, but for a bank that is not this phone's to combine.
    static func canRetry(_ failure: BankHandBack.Failure) -> Bool {
        failure != .alreadyOnPhone
    }
}
