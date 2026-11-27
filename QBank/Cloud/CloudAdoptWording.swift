import Foundation
import QBankKit

/// The words of taking the bank QBank Cloud already holds and of adding this phone's sets to it: the
/// screen that shows both, and their rows in Settings.
enum CloudAdoptWording {
    /// Where the sets offered go: QBank Cloud's bank, from this phone's safety copy, or the bank on
    /// this phone, from its earlier copy.
    enum Into: Equatable {
        case cloud, phone
    }

    static let useCloudBank = "Use my bank in QBank Cloud"
    static var useCloudBankDetail: String { "QBank Cloud holds a bank for you. Your bank is still on this \(Device.model)." }

    static func addSets(_ into: Into) -> String {
        into == .cloud ? "Add sets from this \(Device.model)" : "Add sets from this \(Device.model)'s earlier copy"
    }

    /// Under `addSets` in Settings, and above the sets offered.
    static func addSetsDetail(_ count: Int, into: Into) -> String {
        into == .cloud ? "\(sets(count)) only on this \(Device.model)'s safety copy" : "\(sets(count)) only in this \(Device.model)'s earlier copy"
    }

    // MARK: Looking

    static let lookingTitle = "Looking at QBank Cloud"
    static var lookingNote: String { "QBank is reading the bank QBank Cloud holds for you, to compare it with this \(Device.model)'s. Nothing changes yet." }

    // MARK: Found

    static let foundTitle = "QBank Cloud already has your bank"
    static var foundBody: String {
        "With QBank Cloud on, QBank uses the bank QBank Cloud holds for you, as on your other devices. Nothing on this \(Device.model) is sent up or mixed in."
    }

    /// What only this phone has, said before the switch.
    static func onlyHere(_ count: Int) -> String {
        count == 0
            ? "QBank Cloud has every set on this \(Device.model)."
            : "\(sets(count)) only on this \(Device.model). Next, you can add \(count == 1 ? "it" : "them") to QBank Cloud as \(count == 1 ? "a new set" : "new sets")."
    }

    static var safetyCopy: String {
        "The bank on this \(Device.model) stays on it, unchanged, as a safety copy. Answers you gave on this \(Device.model) to sets QBank Cloud also has stay only in that copy."
    }

    static let use = "Use my bank in QBank Cloud"
    static let notNow = "Not now"

    // MARK: Adopted

    static let adoptedTitle = "QBank uses your bank in QBank Cloud"
    static var adoptedBody: String { "The bank this \(Device.model) held stays on it, unchanged, as a safety copy." }

    // MARK: Offering

    static func offeringTitle(_ count: Int, into: Into = .cloud) -> String {
        into == .cloud ? "\(sets(count)) only on this \(Device.model)" : addSetsDetail(count, into: into)
    }

    static func offeringBody(_ count: Int, into: Into = .cloud) -> String {
        let bank = bankName(into, capitalized: true)
        let goes =
            count == 1
            ? "\(bank) does not have this set. It goes in as a new set"
            : "\(bank) does not have these sets. Each one goes in as a new set"
        return "\(goes), in the course or topic and folder of the same name. Nothing in \(bankName(into)) is replaced, renamed or removed."
    }

    static func add(_ count: Int, into: Into = .cloud) -> String {
        count == 1 ? "Add it to \(bankName(into))" : "Add all \(count) to \(bankName(into))"
    }

    /// The bank the sets go into, as a sentence names it.
    private static func bankName(_ into: Into, capitalized: Bool = false) -> String {
        into == .cloud ? "QBank Cloud" : capitalized ? "Your bank" : "your bank"
    }

    /// The copy the sets come from.
    private static func copyName(_ into: Into) -> String {
        into == .cloud ? "safety copy" : "earlier copy"
    }

    /// Where a set offered is on this phone, as its row says it.
    static func place(_ place: BankOffer.PhoneSet.Place) -> String {
        let course = place.kind == .topic || place.code.isEmpty ? place.title : "\(place.code) \(place.title)"
        guard let folder = place.folder else { return course }
        return "\(course) · \(folder)"
    }

    // MARK: Adding

    static func adding(_ done: Int, of total: Int) -> String {
        "Adding \(min(done + 1, total)) of \(total)"
    }

    static func addingTitle(_ count: Int, into: Into = .cloud) -> String {
        count == 1 ? "Adding your set to \(bankName(into))" : "Adding your sets to \(bankName(into))"
    }

    // MARK: Added

    static func addedTitle(_ count: Int, into: Into = .cloud) -> String {
        count == 1 ? "Your set is in \(bankName(into))" : "Your sets are in \(bankName(into))"
    }

    static func addedBody(_ count: Int, into: Into = .cloud) -> String {
        "QBank added \(sets(count)) to \(bankName(into)) as \(count == 1 ? "a new set" : "new sets"). The \(copyName(into)) on this \(Device.model) is as it was."
    }

    // MARK: Failed

    static let failedTitle = "QBank Cloud's bank is not in use yet"
    static let addFailedTitle = "Not every set was added"
    static let addedNotNotedTitle = "Your sets were added"
    static let tryAgain = "Try again"
    static let ok = "OK"
    static let done = "Done"
    static var notOnThisPhone: String { "There is no bank on this \(Device.model) to compare with QBank Cloud." }
    static func notAdded(_ into: Into) -> String {
        "\(bankName(into, capitalized: true)) did not take this set."
    }

    /// What stayed as it was after adding stopped. `allAdded` when no set is left to add.
    static func addUnchanged(_ into: Into, allAdded: Bool) -> String {
        let unchanged = "Nothing in \(bankName(into)) was replaced, renamed or removed, and the \(copyName(into)) on this \(Device.model) is as it was."
        return allAdded ? unchanged : "\(unchanged) The sets not added yet stay offered in Settings."
    }

    /// Some sets went and one did not.
    static func someAdded(_ added: Int, of total: Int, problem: String) -> String {
        added == 0 ? problem : "QBank added \(added) of \(total) sets. \(problem)"
    }

    /// Every set went, but this phone could not note it.
    static func addedNotNoted(_ count: Int, into: Into = .cloud) -> String {
        "QBank added \(sets(count)) to \(bankName(into)), but this \(Device.model) could not note it, so it may offer \(count == 1 ? "it" : "them") again."
    }

    /// Why this phone did not take QBank Cloud's bank.
    static func problem(_ failure: BankAdoption.Failure) -> String {
        switch failure {
        case .notDownloaded(let error):
            notDownloaded(error)
        case .notReadable:
            "QBank Cloud's bank could not be read, so this \(Device.model) keeps its own."
        case .notRead:
            "The bank on this \(Device.model) could not be read to compare it with QBank Cloud's."
        case .notStarted, .switchNotRecorded:
            "This \(Device.model) could not note the switch, so it keeps using its own bank."
        case .alreadyInCloud:
            "QBank uses your bank in QBank Cloud already."
        case .moving:
            "Your bank is moving, so QBank Cloud's bank is not taken now."
        }
    }

    /// Whether trying again may end differently.
    static func canRetry(_ failure: BankAdoption.Failure) -> Bool {
        switch failure {
        case .alreadyInCloud, .moving: false
        default: true
        }
    }

    /// Why QBank Cloud's bank did not arrive.
    static func notDownloaded(_ error: QBankError) -> String {
        switch error {
        case .transport(.notConnectedToInternet), .transport(.dataNotAllowed), .transport(.internationalRoamingOff):
            "No connection, so QBank Cloud's bank could not be read. Check Wi-Fi or cellular data and try again."
        case .transport:
            "The connection dropped before QBank Cloud's bank arrived."
        default:
            CloudReturnWording.notDownloaded(error)
        }
    }

    /// "1 set", "3 sets".
    static func sets(_ count: Int) -> String {
        count == 1 ? "1 set" : "\(count) sets"
    }
}
