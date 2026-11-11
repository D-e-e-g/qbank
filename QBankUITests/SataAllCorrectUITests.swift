import XCTest

/// A select-all question whose every option is correct, through the Debug launch seam.
/// Invented questions only. Picking every option is full credit, and no choice is marked wrong or missed.
final class SataAllCorrectUITests: XCTestCase {
    private static let set = "Safe Blood Draw"
    private static let optionCount = 4

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testPickingEveryOptionIsFullyCorrect() throws {
        let app = launch("sata-all-correct")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Weeks 1-3")
        let set = app.buttons["course.set.\(Self.set)"]
        XCTAssertTrue(set.appears(timeout: 5))
        tapVisible(set, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))

        let counter = app.staticTexts["practice.count"]
        XCTAssertTrue(counter.appears(timeout: 5))
        XCTAssertTrue(counter.label.hasPrefix("1 of 1"), counter.label)
        let meta = app.descendants(matching: .any)["practice.meta"]
        XCTAssertTrue(meta.label.hasPrefix("Select all that apply"), meta.label)
        XCTAssertFalse(app.buttons["practice.check"].isEnabled, "nothing picked yet")

        for option in 0..<Self.optionCount {
            let row = app.buttons["practice.option.\(option)"]
            tapVisible(row, in: app)
            XCTAssertTrue(row.isSelected)
        }
        attach(app, "sata all correct, every option picked")

        let check = app.buttons["practice.check"]
        XCTAssertTrue(check.isEnabled)
        check.tap()
        let feedback = app.descendants(matching: .any)["practice.feedback"]
        XCTAssertTrue(feedback.appears(timeout: 5))
        XCTAssertTrue(feedback.label.hasPrefix("Correct"), feedback.label)
        XCTAssertTrue(feedback.label.contains("\(Self.optionCount) of \(Self.optionCount) points"), feedback.label)
        XCTAssertFalse(feedback.label.contains("Partly correct"), feedback.label)
        XCTAssertFalse(feedback.label.contains("Not correct"), feedback.label)
        attach(app, "sata all correct, full credit")
        for option in 0..<Self.optionCount {
            let row = app.buttons["practice.option.\(option)"]
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains("Your answer - Correct") || row.label.contains("YOUR ANSWER - CORRECT"), row.label)
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("Missed"), row.label)
            XCTAssertFalse(row.label.localizedCaseInsensitiveContains("Not correct"), row.label)
        }
    }
}
