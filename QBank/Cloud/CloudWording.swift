import Foundation
import QBankKit

/// The words of QBank Cloud: its row in Settings and the plans sheet.
nonisolated enum CloudWording {
    static let title = "QBank Cloud"

    /// What Cloud is, at the top of the plans sheet, with what it needs a connection for.
    static let lead =
        "QBank Cloud keeps your question bank on the QBank service, so the same sets and progress are on every iPhone and iPad where you sign in. With Cloud, practice works without a connection; exams and adding sets need one."

    /// What the App Store asks every subscription to say before it is bought.
    static let autoRenew =
        "Payment is charged to your Apple Account when you confirm the purchase. The subscription renews automatically for the same period and price unless you cancel it at least 24 hours before the current period ends. Manage or cancel it at any time in your Apple Account's subscription settings."

    static let subscribe = "Subscribe"
    static let restore = "Restore purchases"
    static let manage = "Manage subscription"
    static let privacyPolicy = "Privacy policy"
    static let termsOfUse = "Terms of use"

    /// Under a plan's name: how long one payment lasts, and that it renews.
    static func periodLine(_ period: CloudPeriod) -> String {
        "\(period.text), renews automatically"
    }

    static let activeTitle = "QBank Cloud is on"

    /// Under `activeTitle`: when the period paid for ends.
    static func paidUntil(_ date: Date) -> String {
        "Paid until \(day(date))"
    }

    /// Settings' value for the row: On, Off, or nothing until the server has said.
    static func settingsValue(_ status: CloudStatus?) -> String? {
        status.map { $0.active ? "On" : "Off" }
    }

    /// Settings' line under the row: when the paid period ends, when Cloud ended, or what it offers.
    static func settingsDetail(_ status: CloudStatus?) -> String {
        guard let status, let expiresAt = status.expiresAt else { return offer }
        return status.active ? paidUntil(expiresAt) : "Ended \(day(expiresAt))"
    }

    static let offer = "Your bank on every iPhone and iPad"

    static let pending = "Your purchase is waiting for approval. QBank Cloud turns on once it is approved."
    static let restored = "Your subscription is restored. QBank Cloud is on."
    static let nothingToRestore = "This Apple Account has no QBank Cloud subscription to restore."
    static let notActive = "This subscription is not active now, so QBank Cloud stays off."
    static let notConfirmedYet =
        "Your purchase went through with Apple, but QBank could not confirm it yet. It tries again the next time QBank opens or you come back here."
    static let unverified = "The App Store could not verify this purchase, so QBank did not use it. Try Restore purchases."
    static let appStoreProblem = "The App Store could not finish this. Try again."
    static let plansUnavailable = "The plans could not be loaded from the App Store. Try again."
    static let manageUnavailable = "Your Apple Account's subscriptions could not be opened. Try again."
    static let needsServer = "QBank is not connected to its service yet. Sign in with Apple again from Settings."

    /// A date as the plans sheet and Settings say it: "Dec 3, 2027".
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
