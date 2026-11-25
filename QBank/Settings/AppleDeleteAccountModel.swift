import Observation
import QBankKit
import UIKit

/// Delete account for a store account, free or Cloud, which has no password: QBank's server is
/// checked first, then a fresh Sign in with Apple confirms it, and `AppModel.deleteAccount(confirmedWith:nonce:)`
/// erases this phone's copy, deletes the account on the server and forgets the session, in that
/// order. The same screen finishes a delete that stopped after the erase. An invited account keeps
/// `DeleteAccountModel` and its password.
@Observable
final class AppleDeleteAccountModel {
    private(set) var isDeleting = false
    /// Why the last try stopped, or nil.
    private(set) var problem: String?

    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        // The screen that finishes a delete opens with the reason the last try stopped.
        problem = app.deletionProblem
    }

    /// Settings offers it to a store account, which has no password. The admin is never one.
    static func isOffered(to account: Account?, kind: AccountKind) -> Bool {
        !kind.deletesWithPassword && account?.origin == .store && account?.role == .student
    }

    /// True once this phone's copy is erased, or being erased: only finishing the delete is left.
    var isFinishing: Bool {
        app.isFinishingDeletion
    }

    /// Checks QBank's server, asks Apple over `window`, then deletes. Closing Apple's sheet says
    /// nothing and deletes nothing.
    func delete(over window: UIWindow?) async {
        guard !isDeleting else { return }
        isDeleting = true
        problem = nil
        defer { isDeleting = false }
        do throws(AppModel.DeletionStop) {
            try await app.checkBeforeDeletingAccount()
            let nonce = AppleSignInNonce()
            let credential: AppleCredential
            do {
                credential = try await app.appleSignIn.signIn(hashedNonce: nonce.hashed, over: window)
            } catch {
                problem = error == .canceled ? nil : AppleSignInWording.appleDidNotFinish
                return
            }
            try await app.deleteAccount(confirmedWith: credential, nonce: nonce)
        } catch {
            problem = error.reason
        }
    }
}
