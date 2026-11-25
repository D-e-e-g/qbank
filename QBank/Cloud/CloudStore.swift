import Foundation
import UIKit

/// The App Store as Cloud uses it: the plans it sells, a purchase, and the transactions it signs. A
/// real build talks to StoreKit 2 (`StoreKitCloudStore`); a Debug launch scenario gives a fake
/// (`DebugFakeStore`), so a test never reaches the App Store.
///
/// The App Store's word never turns Cloud on by itself: `CloudModel` sends each transaction to QBank's
/// server, and finishes it only once the server answers that Cloud is active.
protocol CloudStore: AnyObject {
    /// The Cloud plans the App Store sells in this storefront, with their names, periods and prices.
    /// Empty when it sells none here, or before App Store Connect has them.
    func plans() async throws(CloudStoreFailure) -> [CloudPlan]

    /// Buys `planID` for the account whose token is `token`, which the transaction Apple signs carries
    /// as its `appAccountToken`. Apple's sheet opens over `scene`.
    func buy(_ planID: String, token: UUID, in scene: UIWindowScene?) async throws(CloudStoreFailure) -> CloudPurchase

    /// Every Cloud transaction the App Store gives the app outside a purchase made here: a renewal, a
    /// purchase on another device, an Ask to Buy approved later, a refund, and, at launch, each one not
    /// yet finished. It runs as long as the app does.
    func updates() -> AsyncStream<CloudTransaction>

    /// The Cloud transactions not finished yet, such as a purchase QBank's server could not confirm when
    /// it was made.
    func unfinished() async -> [CloudTransaction]

    /// The latest transaction of each Cloud subscription the Apple Account has now, for Restore.
    func currentEntitlements() async -> [CloudTransaction]

    /// Brings the App Store's record of the Apple Account's purchases up to date, which may ask the
    /// person to sign in to their Apple Account. Restore calls it first.
    func sync() async throws(CloudStoreFailure)

    /// Apple's own Manage subscription sheet, over `scene`, to change plans or cancel. Returns once it
    /// is closed.
    func manageSubscriptions(in scene: UIWindowScene?) async throws(CloudStoreFailure)
}

/// A Cloud plan as the App Store sells it.
nonisolated struct CloudPlan: Identifiable, Equatable, Sendable {
    /// The product id, one of `CloudProducts`.
    let id: String
    /// The App Store's name for it, such as "QBank Cloud Monthly".
    let name: String
    /// How long one payment lasts.
    let period: CloudPeriod
    /// The App Store's price for one period, in the storefront's currency, such as "$4.99".
    let price: String
}

/// How long one payment of a plan lasts: one month, one year.
nonisolated struct CloudPeriod: Equatable, Sendable {
    enum Unit: String, Sendable {
        case day, week, month, year
    }

    let value: Int
    let unit: Unit

    /// "1 month", "1 year", "3 months".
    var text: String {
        "\(value) \(unit.rawValue)\(value == 1 ? "" : "s")"
    }
}

/// A Cloud transaction the App Store signed: what goes to QBank's server, and how to tell the App Store
/// it was delivered.
nonisolated struct CloudTransaction: Sendable {
    /// The App Store's id of the transaction.
    let id: UInt64
    let productID: String
    /// The transaction as the App Store signed it (StoreKit's `jwsRepresentation`), which the server
    /// checks with Apple's certificates.
    let signed: String
    /// Tells the App Store the purchase was delivered, so it stops giving it to the app again.
    let finish: @Sendable () async -> Void
}

/// How a purchase ended at the App Store.
nonisolated enum CloudPurchase: Sendable {
    /// Paid: the transaction to send to QBank's server, still unfinished.
    case purchased(CloudTransaction)
    /// Waiting for someone to approve it, as Ask to Buy does. The transaction comes later, through
    /// `CloudStore.updates()`.
    case pending
    /// The person closed Apple's sheet.
    case cancelled
    /// The App Store gave back a transaction it could not verify itself. QBank sends it nowhere.
    case unverified
}

/// Why the App Store did not do what was asked.
nonisolated enum CloudStoreFailure: Error, Equatable, Sendable {
    /// The person closed a sheet of Apple's, such as the Apple Account sign-in of Restore.
    case cancelled
    /// The plan was not loaded from the App Store first.
    case planNotLoaded
    /// The App Store could not be reached, or refused, for its own reason.
    case failed
}
