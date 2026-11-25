/// What the phone says while a store account, free or Cloud, is deleted with a fresh Sign in with
/// Apple, and when that delete stops. Every sentence that ends a try says whether anything was
/// deleted, since this is the one place the person's own bank is erased.
enum AccountDeletionWording {
    /// What goes, said before the delete. The same for a free bank on the phone and a Cloud bank on
    /// the server: the delete erases both sides.
    static var whatGoes: String {
        "Your QBank account and everything in it are deleted for good, on this \(Device.model) and on QBank's server: your courses and study topics, their sets, your answers, progress and past exams. You are signed out on every device. Nothing goes to Recently deleted, and there is no Undo."
    }

    /// Said once this phone's copy is erased, or being erased, and the server has not deleted the
    /// account yet.
    static var finishing: String {
        "Everything QBank kept on this \(Device.model) is erased, but your account on QBank's server is not deleted yet. Delete it to finish."
    }

    /// Under the delete button: Apple's sheet comes first.
    static let appleConfirms = "Apple asks you to confirm it's you before anything is deleted."

    /// A subscription is Apple's to bill, and deleting the account does not end it.
    static let subscription = "Deleting your account does not cancel a QBank Cloud subscription. Apple keeps billing it until you cancel it in Manage subscription."

    /// Apple's sheet confirmed someone other than the person signed in.
    static let otherAppleAccount =
        "Apple confirmed a different Apple Account. Use the Apple Account you signed in to QBank with. Nothing was deleted."

    /// The phone could not keep the record of the delete, so it did not begin.
    static var notBegun: String {
        "This \(Device.model) could not start the delete. Nothing was deleted. Try again."
    }

    /// The erase of this phone's copy failed part way.
    static var phoneNotErased: String {
        "QBank could not erase everything it kept on this \(Device.model). Your account is not deleted yet. Try again."
    }

    /// Something the phone cannot name.
    static let tryAgain = "Something went wrong. Try again."

    /// QBank's server has not confirmed the Sign in with Apple, and still cannot be reached.
    static let awaitsServer =
        "QBank's server has not confirmed your sign-in yet, so your account cannot be deleted now. Nothing was deleted. Try again when QBank can be reached."

    /// QBank's server refused the Sign in with Apple kept to send again: a new one connects first.
    static var needsAppleSignInAgain: String {
        "This \(Device.model) is not connected to the QBank service yet. Sign in with Apple again in Settings to connect it, then delete your account. Nothing was deleted."
    }

    /// The server had ended the session before anything was erased: the person is signed out with
    /// their bank kept.
    static let sessionEndedBeforeErasing = "Your session ended, so nothing was deleted. Sign in with Apple, then delete your account again."

    /// The server had no session for this phone once its copy was erased: an earlier try deleted the
    /// account and its answer never came, or the session ended another way.
    static var sessionEndedAfterErasing: String {
        "Everything QBank kept on this \(Device.model) is erased. QBank had already signed this \(Device.model) out, so if your account is still there when you sign in with Apple, delete it again in Settings."
    }
}
