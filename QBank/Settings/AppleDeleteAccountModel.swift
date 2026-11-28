import Observation
import QBankKit
import UIKit

/// Delete account for a store account, free or Cloud, which has no password: QBank's server is
/// checked first, then a fresh Sign in with Apple confirms it, and `AppModel.deleteAccountWithApple(over:)`
/// erases this phone's copy, deletes the account on the server and forgets the session, in that
/// order. The same screen shows the delete under way from the erase on, and finishes a delete that
/// stopped there. An invited account keeps `DeleteAccountModel` and its password.
@Observable
final class AppleDeleteAccountModel {
    /// Why this screen's last try stopped before anything was erased, or nil.
    private var stopped: String?

    private let app: AppModel
    /// Where the account's bank is, as it was when the screen opened, so the words stay while
    /// signing out fades the screen away.
    private let bankIsOnPhone: Bool
    /// True when the screen opened to finish a delete, so it stays that screen while signing out
    /// fades it away.
    private let opensFinishing: Bool
    /// True when the screen opened on a delete under way, so it stays under way while the sign-in
    /// screen that ends the delete fades it away.
    private let opensUnderWay: Bool
    /// How many deletes had stopped when the screen opened, so one that stops later keeps it the
    /// finishing screen while signing out fades it away.
    private let stopsSeen: Int

    init(app: AppModel) {
        self.app = app
        bankIsOnPhone = app.kind.bankIsOnPhone
        opensFinishing = app.isFinishingDeletion
        if case .deletingAccount = app.route { opensUnderWay = true } else { opensUnderWay = false }
        stopsSeen = app.deletesStopped
    }

    /// Settings offers it to a store account, which has no password. The admin is never one.
    static func isOffered(to account: Account?, kind: AccountKind) -> Bool {
        !kind.deletesWithPassword && account?.origin == .store && account?.role == .student
    }

    /// True while a delete runs, whichever screen began it.
    var isDeleting: Bool {
        app.isDeletingAccount || (opensUnderWay && !isFinishing)
    }

    /// Why the last try stopped, or nil. Once the delete is to be finished, it is the app's, so the
    /// screen that finishes the delete says it too.
    var problem: String? {
        isFinishing ? app.deletionProblem : stopped
    }

    /// True once a delete stopped with this phone's copy erased, or partly erased: finishing the
    /// delete or signing out is offered. A delete under way is not one to finish.
    var isFinishing: Bool {
        opensFinishing || app.isFinishingDeletion || app.deletesStopped != stopsSeen
    }

    /// What the screen says: what goes, for where this account's bank is, or what is left to finish.
    var message: String {
        isFinishing ? AccountDeletionWording.finishing(phoneErased: app.phoneCopyErased) : AccountDeletionWording.whatGoes(bankIsOnPhone: bankIsOnPhone)
    }

    /// Checks QBank's server, asks Apple over `window`, then deletes. Closing Apple's sheet says
    /// nothing and deletes nothing.
    func delete(over window: UIWindow?) async {
        guard !isDeleting else { return }
        stopped = nil
        do throws(AppModel.DeletionStop) {
            try await app.deleteAccountWithApple(over: window)
        } catch {
            stopped = error.reason
        }
    }

    /// Leaves a delete to finish without finishing it: the session and the record of the delete are
    /// forgotten, and the account stays on QBank's server until the person signs in and deletes it.
    func signOut() async {
        guard app.isFinishingDeletion, !isDeleting else { return }
        await app.signOut()
    }
}
