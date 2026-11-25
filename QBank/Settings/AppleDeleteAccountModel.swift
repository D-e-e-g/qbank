import Observation
import QBankKit
import UIKit

/// Delete account for a store account, free or Cloud, which has no password: QBank's server is
/// checked first, then a fresh Sign in with Apple confirms it, and `AppModel.deleteAccountWithApple(over:)`
/// erases this phone's copy, deletes the account on the server and forgets the session, in that
/// order. The same screen finishes a delete that stopped after the erase. An invited account keeps
/// `DeleteAccountModel` and its password.
@Observable
final class AppleDeleteAccountModel {
    /// Why this screen's last try stopped before anything was erased, or nil.
    private var stopped: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    /// Settings offers it to a store account, which has no password. The admin is never one.
    static func isOffered(to account: Account?, kind: AccountKind) -> Bool {
        !kind.deletesWithPassword && account?.origin == .store && account?.role == .student
    }

    /// True while a delete runs, whichever screen began it.
    var isDeleting: Bool {
        app.isDeletingAccount
    }

    /// Why the last try stopped, or nil. Once this phone's copy is erased, or being erased, it is the
    /// app's, so the screen that finishes the delete says it too.
    var problem: String? {
        isFinishing ? app.deletionProblem : stopped
    }

    /// True once this phone's copy is erased, or being erased: only finishing the delete is left.
    var isFinishing: Bool {
        app.isFinishingDeletion
    }

    /// What the screen says: what goes, for where this account's bank is, or what is left to finish.
    var message: String {
        isFinishing ? AccountDeletionWording.finishing : AccountDeletionWording.whatGoes(bankIsOnPhone: app.kind.bankIsOnPhone)
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
        guard isFinishing, !isDeleting else { return }
        await app.signOut()
    }
}
