import XCTest

/// QBank Cloud for a free account: Settings' Cloud row, the plans sheet, and a purchase that the
/// server turns into Cloud. The App Store is the fake store and the server the fake one, through the
/// Debug launch seam, so nothing is bought and no Apple Account is used. A unit test cannot do this
/// job: it is the real sheet, as presented over Settings, that must show each plan's name, period and
/// price, the renewal terms and the two policy links, and a real tap through StoreKit's stand-in to
/// the server that must leave Settings saying Cloud is on. Both run on iPhone and iPad, where the
/// sheet is the same and Settings is reached the same way.
final class CloudUITests: XCTestCase {
    /// Each plan as the fake store sells it, as the StoreKit configuration file does: the key of its
    /// controls, its name, how long one payment lasts, and its price.
    private static let plans = [
        ("monthly", "QBank Cloud Monthly", "1 month, renews automatically", "$4.99"),
        ("yearly", "QBank Cloud Yearly", "1 year, renews automatically", "$29.99"),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThePlansSheetShowsPricePeriodAndLegalLinks() {
        let app = launch("free-new-bank")
        let cloud = openCloudRow(app)
        waitForLabel(cloud, containing: "Off")
        cloud.tap()
        XCTAssertTrue(app.navigationBars["QBank Cloud"].appears(timeout: 5))

        for (key, name, period, price) in Self.plans {
            let shown = app.staticTexts["cloud.plan.\(key).name"]
            XCTAssertTrue(shown.appears(timeout: 5), key)
            XCTAssertEqual(shown.label, name)
            XCTAssertEqual(app.staticTexts["cloud.plan.\(key).period"].label, period)
            XCTAssertEqual(app.staticTexts["cloud.plan.\(key).price"].label, price)
            XCTAssertTrue(app.buttons["cloud.plan.\(key).subscribe"].isEnabled, key)
        }
        let renewal = app.staticTexts["cloud.autoRenew"]
        XCTAssertTrue(renewal.label.contains("renews automatically for the same period and price"), renewal.label)
        XCTAssertTrue(renewal.label.contains("at least 24 hours before the current period ends"), renewal.label)
        attach(app, "cloud plans sheet")

        let links = [
            ("cloud.privacy", "https://qbank-app.dimitrygallego.com/privacy"),
            ("cloud.terms", "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"),
        ]
        for (id, address) in links {
            let row = app.buttons[id]
            reveal(row, in: app)
            row.tap()
            let page = app.staticTexts["webpage.address"]
            XCTAssertTrue(page.appears(timeout: 5), id)
            XCTAssertEqual(page.label, address)
            app.buttons["webpage.done"].tap()
            XCTAssertTrue(page.disappears(timeout: 5), id)
        }
        XCTAssertTrue(app.buttons["cloud.restore"].exists)
    }

    @MainActor
    func testAPurchaseTurnsCloudOn() {
        let app = launch("free-new-bank")
        let cloud = openCloudRow(app)
        waitForLabel(cloud, containing: "Off")
        cloud.tap()

        let subscribe = app.buttons["cloud.plan.monthly.subscribe"]
        XCTAssertTrue(subscribe.appears(timeout: 5))
        subscribe.tap()

        // The server, not the store, says Cloud is on: the sheet shows it in place of the plans.
        let active = app.descendants(matching: .any)["cloud.active"]
        XCTAssertTrue(active.appears(timeout: 10))
        XCTAssertTrue(active.label.contains("QBank Cloud is on"), active.label)
        XCTAssertTrue(app.staticTexts["cloud.paidUntil"].label.hasPrefix("Paid until "))
        XCTAssertTrue(app.buttons["cloud.manage"].exists)
        XCTAssertFalse(app.buttons["cloud.plan.monthly.subscribe"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["problem"].exists)
        attach(app, "cloud on")

        app.buttons["cloud.done"].tap()
        XCTAssertTrue(app.navigationBars["QBank Cloud"].disappears(timeout: 5))
        waitForLabel(cloud, containing: "On")
        XCTAssertTrue(cloud.label.contains("Paid until"), cloud.label)
        attach(app, "settings with cloud on")
    }

    /// Opens Settings on the free account's first screen and finds the Cloud row.
    @MainActor
    private func openCloudRow(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openTab(app, "Settings")
        let cloud = app.buttons["settings.cloud"]
        XCTAssertTrue(cloud.appears(timeout: 5))
        return cloud
    }
}
