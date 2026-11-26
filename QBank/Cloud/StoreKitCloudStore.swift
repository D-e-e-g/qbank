import QBankKit
import StoreKit
import UIKit

/// Cloud's App Store in a real build: StoreKit 2. It loads the two Cloud plans, buys one with the
/// account's token, and hands on every Cloud transaction StoreKit verified on this device, still
/// unfinished, for `CloudModel` to send to QBank's server. A transaction StoreKit could not verify is
/// handed on to no one: the server, which checks the same signature, would refuse it too.
final class StoreKitCloudStore: CloudStore {
    /// The products loaded last, by id: a purchase buys one of them.
    private var products: [String: Product] = [:]

    func plans() async throws(CloudStoreFailure) -> [CloudPlan] {
        let loaded: [Product]
        do {
            loaded = try await Product.products(for: CloudProducts.all)
        } catch {
            throw Self.failure(error)
        }
        products = Dictionary(loaded.map { ($0.id, $0) }) { first, _ in first }
        return loaded.compactMap(Self.plan)
    }

    func buy(_ planID: String, token: UUID, in scene: UIWindowScene?) async throws(CloudStoreFailure) -> CloudPurchase {
        guard let product = products[planID] else { throw .planNotLoaded }
        let options: Set<Product.PurchaseOption> = [.appAccountToken(token)]
        let result: Product.PurchaseResult
        do {
            if let scene {
                result = try await product.purchase(confirmIn: scene, options: options)
            } else {
                result = try await product.purchase(options: options)
            }
        } catch {
            throw Self.failure(error)
        }
        switch result {
        case .success(let verification):
            return Self.transaction(verification).map(CloudPurchase.purchased) ?? .unverified
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            // An outcome this version does not know: nothing was bought that it can deliver.
            return .cancelled
        }
    }

    func updates() -> AsyncStream<CloudTransaction> {
        AsyncStream { continuation in
            let listener = Task {
                for await result in Transaction.updates {
                    if let transaction = Self.transaction(result) {
                        continuation.yield(transaction)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in listener.cancel() }
        }
    }

    func unfinished() async -> [CloudTransaction] {
        await Self.collect(Transaction.unfinished)
    }

    func currentEntitlements() async -> [CloudTransaction] {
        await Self.collect(Transaction.currentEntitlements)
    }

    func sync() async throws(CloudStoreFailure) {
        do {
            try await AppStore.sync()
        } catch {
            throw Self.failure(error)
        }
    }

    func manageSubscriptions(in scene: UIWindowScene?) async throws(CloudStoreFailure) {
        guard let scene else { throw .failed }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            throw Self.failure(error)
        }
    }

    private static func collect(_ transactions: Transaction.Transactions) async -> [CloudTransaction] {
        var collected: [CloudTransaction] = []
        for await result in transactions {
            if let transaction = transaction(result) {
                collected.append(transaction)
            }
        }
        return collected
    }

    /// A Cloud transaction StoreKit verified, with what Apple signed of it. Nil for one it could not
    /// verify, and for any other product's.
    private static func transaction(_ result: VerificationResult<Transaction>) -> CloudTransaction? {
        guard case .verified(let transaction) = result, CloudProducts.all.contains(transaction.productID) else { return nil }
        return CloudTransaction(id: transaction.id, productID: transaction.productID, signed: result.jwsRepresentation) {
            await transaction.finish()
        }
    }

    /// A Cloud plan as the plans sheet shows it, or nil for a product that is not a subscription.
    private static func plan(_ product: Product) -> CloudPlan? {
        guard let period = product.subscription?.subscriptionPeriod, let unit = unit(period.unit) else { return nil }
        return CloudPlan(id: product.id, name: product.displayName, period: CloudPeriod(value: period.value, unit: unit), price: product.displayPrice)
    }

    private static func unit(_ unit: Product.SubscriptionPeriod.Unit) -> CloudPeriod.Unit? {
        switch unit {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        @unknown default: nil
        }
    }

    private static func failure(_ error: any Error) -> CloudStoreFailure {
        if case StoreKitError.userCancelled = error { return .cancelled }
        return .failed
    }
}
