#if DEBUG
import Foundation
import QBankKit
import UIKit

/// The fake store of a launch scenario: the stand-in a UI test drives in place of StoreKit, so a
/// test never reaches the App Store or makes a purchase. Reached from `DebugScenarioContext.store`.
/// Compiled only into Debug builds.
///
/// It sells the two Cloud plans with the names, periods and US prices of the StoreKit configuration
/// file, `StoreKit/QBankCloud.storekit`. A purchase answers at once, as Apple would after the person
/// confirmed, with a transaction the fake server reads (`FakeQBankServer.storeTransaction`): the plan,
/// the token the app bought with, and when the period it pays for ends. It keeps which of its
/// transactions the app finished, as the App Store does, and gives the rest again as unfinished.
final class DebugFakeStore: CloudStore {
    /// The two plans, as the StoreKit configuration file sells them in the United States.
    nonisolated static let plans = [
        CloudPlan(id: CloudProducts.monthly, name: "QBank Cloud Monthly", period: CloudPeriod(value: 1, unit: .month), price: "$4.99"),
        CloudPlan(id: CloudProducts.yearly, name: "QBank Cloud Yearly", period: CloudPeriod(value: 1, unit: .year), price: "$29.99"),
    ]

    /// Every transaction bought, in order.
    private(set) var bought: [CloudTransaction] = []
    /// The ids of the transactions the app finished.
    private(set) var finished: Set<UInt64> = []
    private let updateStream = AsyncStream.makeStream(of: CloudTransaction.self)

    func plans() async throws(CloudStoreFailure) -> [CloudPlan] {
        Self.plans
    }

    func buy(_ planID: String, token: UUID, in scene: UIWindowScene?) async throws(CloudStoreFailure) -> CloudPurchase {
        guard let plan = Self.plans.first(where: { $0.id == planID }) else { throw .planNotLoaded }
        let id = UInt64(bought.count + 1)
        let ends = Self.end(of: plan.period, from: .now)
        let transaction = CloudTransaction(
            id: id, productID: planID, signed: FakeQBankServer.storeTransaction(id: id, product: planID, token: token, expiresAt: ends)
        ) { [weak self] in
            await self?.finish(id)
        }
        bought.append(transaction)
        return .purchased(transaction)
    }

    /// Nothing renews or arrives from another device during a test, so nothing comes.
    func updates() -> AsyncStream<CloudTransaction> {
        updateStream.stream
    }

    func unfinished() async -> [CloudTransaction] {
        bought.filter { !finished.contains($0.id) }
    }

    func currentEntitlements() async -> [CloudTransaction] {
        bought
    }

    func sync() async throws(CloudStoreFailure) {}

    func manageSubscriptions(in scene: UIWindowScene?) async throws(CloudStoreFailure) {}

    private func finish(_ id: UInt64) {
        finished.insert(id)
    }

    /// When a period bought now ends.
    private static func end(of period: CloudPeriod, from start: Date) -> Date {
        let component: Calendar.Component =
            switch period.unit {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        return Calendar(identifier: .gregorian).date(byAdding: component, value: period.value, to: start) ?? start
    }
}
#endif
