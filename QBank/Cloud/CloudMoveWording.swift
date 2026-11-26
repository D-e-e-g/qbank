import Foundation
import QBankKit

/// The words of moving the bank to QBank Cloud: the move's screen, its row in Settings and its place on
/// the plans sheet. A refusal from the server is said in the server's own sentence, which is written to
/// be shown as it is.
enum CloudMoveWording {
    static let move = "Move my bank to QBank Cloud"
    static var stillOnPhone: String { "Your bank is still on this \(Device.model)." }
    static let inCloud = "Your bank is in QBank Cloud."

    // MARK: Moving

    static let movingTitle = "Moving your bank to QBank Cloud"
    static let movingNote = "Keep QBank open. Your bank can't change until the move ends."
    static let resumedNote = "QBank was closed before the move ended, so it is moving your bank again from the start."

    /// Each step, as the screen lists it.
    static func step(_ step: BankMoveToCloud.Step) -> String {
        switch step {
        case .writing: "Preparing a copy of your bank"
        case .sending: "Sending it to QBank Cloud"
        case .checking: "Checking that everything arrived"
        }
    }

    // MARK: Moved

    static let movedTitle = "Your bank is in QBank Cloud"
    static var movedBody: String {
        "QBank Cloud counted the same sets, questions, answers and progress as this \(Device.model), so QBank now uses your bank in QBank Cloud."
    }
    static var safetyCopy: String { "The bank this \(Device.model) held before the move stays on it, unchanged, as a safety copy." }

    /// The counts the moved screen shows, by archive key, with what each counts.
    static let shownCounts: [(table: String, label: String)] = [
        ("practiceSets", "Sets, with earlier versions"),
        ("questions", "Questions"),
        ("attempts", "Answers"),
    ]

    // MARK: Failed

    static var failedTitle: String { "Your bank stays on this \(Device.model)" }
    static var unchanged: String { "Your bank on this \(Device.model) is as it was, and you can keep using it." }
    static let tryAgain = "Try again"
    static let notNow = "Not now"
    static let ok = "OK"
    static var notOnThisPhone: String { "There is no bank on this \(Device.model) to move." }

    /// Why a move did not switch the bank to QBank Cloud.
    static func problem(_ failure: BankMoveToCloud.Failure) -> String {
        switch failure {
        case .notStarted:
            "This \(Device.model) could not note that a move was starting, so it did not start."
        case .alreadyInCloud:
            inCloud
        case .notRead:
            "Your bank on this \(Device.model) could not be read to send it."
        case .notStored(let error):
            notStored(error)
        case .countsDiffer(let differences):
            "QBank Cloud does not hold the same number of \(list(differences.map { name(of: $0.table) })) as this \(Device.model), so QBank keeps using the bank on this \(Device.model)."
        case .switchNotRecorded:
            "Your bank reached QBank Cloud whole, but this \(Device.model) could not note the switch, so it keeps using the bank here."
        }
    }

    /// Whether trying the move again may end differently. Not after QBank Cloud refused the bank or
    /// took one whose counts did not match: it now holds a bank for the account, or refuses this one,
    /// and would refuse the same upload again. A lost or unreadable answer may hide either, so the
    /// person may try.
    static func canRetry(_ failure: BankMoveToCloud.Failure) -> Bool {
        switch failure {
        case .notStarted, .notRead: true
        case .alreadyInCloud, .countsDiffer, .switchNotRecorded: false
        case .notStored(.unexpectedResponse): true
        case .notStored(let error): error.isTemporary
        }
    }

    /// Why an upload did not come back as stored. A refusal the server explains is said in its words;
    /// a lost or unreadable answer says QBank Cloud did not confirm the bank, since it may have arrived.
    static func notStored(_ error: QBankError) -> String {
        switch error {
        case .server(let refusal) where refusal.status < 500:
            return refusal.message
        case .server, .unexpectedResponse(500..., _):
            return "QBank Cloud could not take your bank right now. Try again in a moment."
        case .unexpectedResponse:
            return "QBank Cloud's answer could not be read, so it has not confirmed it holds your whole bank."
        case .transport(.notConnectedToInternet), .transport(.dataNotAllowed), .transport(.internationalRoamingOff):
            return "No connection, so your bank was not sent. Check Wi-Fi or cellular data and try again."
        case .transport(.timedOut):
            return "QBank Cloud did not answer in time, so it has not confirmed it holds your whole bank."
        case .transport(.userAuthenticationRequired):
            return "This \(Device.model) is not connected to the QBank service yet, so your bank was not sent."
        case .transport:
            return "The connection to QBank Cloud dropped before it confirmed it holds your whole bank."
        case .cancelled:
            return "The move stopped before QBank Cloud confirmed it holds your whole bank."
        case .notSignedIn, .storage, .invalidRequest:
            return "Your bank could not be sent. Try again."
        }
    }

    /// What a table of the bank holds, as a person says it.
    static func name(of table: String) -> String {
        switch table {
        case "semesters": "semesters"
        case "courses": "courses and topics"
        case "courseExams": "pages"
        case "folders": "folders"
        case "practiceSets": "sets"
        case "questions": "questions"
        case "terms": "terms"
        case "studySessions": "sittings and exams"
        case "attempts": "answers"
        case "questionProgress": "questions with progress"
        case "reviewClears": "cleared Review questions"
        case "studyPlace": "places you left off"
        default: table
        }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
