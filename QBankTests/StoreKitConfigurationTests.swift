import Foundation
import QBankKit
import Testing
@testable import QBank

/// The StoreKit configuration file, `StoreKit/QBankCloud.storekit`, which sells the two Cloud plans to
/// a run from Xcode: its plans are the products App Store Connect and the server know, at the periods
/// and US prices of the plans, the fake store of UI tests sells the same, and the app never carries the
/// file. It is read from the repository, beside this test's folder.
struct StoreKitConfigurationTests {
    private struct Configuration: Decodable {
        struct Settings: Decodable {
            let locale: String
            let storefront: String

            enum CodingKeys: String, CodingKey {
                case locale = "_locale"
                case storefront = "_storefront"
            }
        }

        struct Group: Decodable {
            let name: String
            let subscriptions: [Subscription]
        }

        struct Subscription: Decodable {
            let productID: String
            let referenceName: String
            let recurringSubscriptionPeriod: String
            let displayPrice: String
            let familyShareable: Bool
            let type: String
            let localizations: [Localization]
            /// Absent: the plans have no free trial.
            let introductoryOffer: JSONValue?
        }

        struct Localization: Decodable {
            let displayName: String
            let locale: String
        }

        let products: [JSONValue]
        let nonRenewingSubscriptions: [JSONValue]
        let settings: Settings
        let subscriptionGroups: [Group]
    }

    private static func configuration() throws -> Configuration {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "StoreKit/QBankCloud.storekit")
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
    }

    @Test func itSellsTheTwoCloudPlansAtTheirPeriodsAndPricesAndNothingElse() throws {
        let configuration = try Self.configuration()
        #expect(configuration.products.isEmpty)
        #expect(configuration.nonRenewingSubscriptions.isEmpty)
        #expect(configuration.settings.storefront == "USA")
        #expect(configuration.settings.locale == "en_US")
        #expect(configuration.subscriptionGroups.map(\.name) == ["QBank Cloud"])
        let subscriptions = try #require(configuration.subscriptionGroups.first?.subscriptions)
        #expect(subscriptions.map(\.productID) == CloudProducts.all)
        #expect(subscriptions.map(\.productID) == ["com.dimitrygallego.qbank.cloud.monthly", "com.dimitrygallego.qbank.cloud.yearly"])
        #expect(subscriptions.map(\.recurringSubscriptionPeriod) == ["P1M", "P1Y"])
        #expect(subscriptions.map(\.displayPrice) == ["4.99", "29.99"])
        for subscription in subscriptions {
            #expect(subscription.type == "RecurringSubscription", "\(subscription.productID) renews by itself")
            #expect(!subscription.familyShareable, "\(subscription.productID) is not shared with a family")
            #expect(subscription.introductoryOffer == nil, "\(subscription.productID) has no free trial")
            #expect(subscription.localizations.map(\.locale) == ["en_US"])
        }
    }

    @Test func theFakeStoreSellsWhatTheFileSells() throws {
        let configuration = try Self.configuration()
        let subscriptions = try #require(configuration.subscriptionGroups.first?.subscriptions)
        let periods = ["P1M": CloudPeriod(value: 1, unit: .month), "P1Y": CloudPeriod(value: 1, unit: .year)]
        let sold = subscriptions.map { subscription in
            CloudPlan(
                id: subscription.productID, name: subscription.localizations.first?.displayName ?? "",
                period: periods[subscription.recurringSubscriptionPeriod] ?? CloudPeriod(value: 0, unit: .day), price: "$\(subscription.displayPrice)")
        }
        #expect(sold == DebugFakeStore.plans)
        #expect(subscriptions.map(\.referenceName) == DebugFakeStore.plans.map(\.name))
    }

    /// The unit tests run inside the built app, so its bundle is the one a build ships, apart from the
    /// test bundle Xcode adds to it for the run.
    @Test func theAppNeverCarriesAStoreKitConfiguration() throws {
        let app = Bundle.main.bundleURL
        #expect(app.pathExtension == "app")
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "PrivacyInfo.xcprivacy").path()), "this is the app's own bundle")
        let enumerator = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var carried: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "storekit" {
            carried.append(file.lastPathComponent)
        }
        #expect(carried.isEmpty, "the app carries \(carried)")
    }
}
