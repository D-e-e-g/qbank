import XCTest

/// Settings' About rows end to end. A unit test cannot do this job: it is the real screen's rows,
/// reached by scrolling and a tap, that must exist and open a page over Settings. The launch seam
/// shows a stand-in with the address in place of the system browser view, so no network is used.
final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrivacyHelpAndTermsOpen() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openTab(app, "Settings")
        let expected = [
            ("settings.privacy", "https://qbank-app.dimitrygallego.com/privacy"),
            ("settings.help", "https://qbank-app.dimitrygallego.com/support"),
            ("settings.terms", "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"),
        ]
        for (id, address) in expected {
            let row = app.buttons[id]
            reveal(row, in: app)
            XCTAssertTrue(row.isHittable, id)
            row.tap()
            let shown = app.staticTexts["webpage.address"]
            XCTAssertTrue(shown.appears(timeout: 5), id)
            XCTAssertEqual(shown.label, address)
            if id == "settings.privacy" { attach(app, "settings about, privacy page open") }
            app.buttons["webpage.done"].tap()
            XCTAssertTrue(shown.disappears(timeout: 5), id)
        }
    }
}
