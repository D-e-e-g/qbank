import XCTest

/// A free account's first launch: its new bank on the phone holds the sample set the app ships with,
/// so a new person can practice at once, with no network and nothing imported by hand. A unit test
/// cannot do this job: it is the real Home, topic and practice screens over the bank on the phone
/// that show the sample is where a first look finds it and runs as an ordinary set.
final class FirstRunUITests: XCTestCase {
    private let topic = "Getting started"
    private let set = "General knowledge sampler"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchOpensTheSampleSet() throws {
        try skipOnIPad()
        let app = launch("free-first-launch", online: false)

        // Home already has a topic, and in it the sample set.
        let card = app.buttons["home.topic.\(topic)"]
        XCTAssertTrue(card.appears(timeout: 10))
        attach(app, "first launch, home")
        card.tap()
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        let folder = app.buttons["folder.Unsorted"]
        XCTAssertTrue(folder.appears(timeout: 5))
        tapVisible(folder, in: app)
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        let sample = app.buttons["course.set.\(set)"]
        XCTAssertTrue(sample.appears(timeout: 5))
        XCTAssertTrue(sample.label.contains("10"), sample.label)
        attach(app, "first launch, the sample set")

        // It practices like any set: the first question, then the answer with its rationale.
        tapVisible(sample, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["practice.count"].label.hasPrefix("1 of 10"))
        XCTAssertTrue(app.buttons["practice.image"].appears(timeout: 5), "the first question shows its diagram")
        attach(app, "first launch, the first question")
        tapVisible(app.buttons["practice.option.1"], in: app)
        app.buttons["practice.check"].tap()
        let feedback = app.descendants(matching: .any)["practice.feedback"]
        XCTAssertTrue(feedback.appears(timeout: 5))
        let rationale = app.descendants(matching: .any)["practice.rationale"]
        XCTAssertTrue(rationale.appears(timeout: 5))
        XCTAssertTrue(rationale.label.contains("Mercury orbits closest"), rationale.label)
        attach(app, "first launch, practice")
        app.buttons["practice.close"].tap()
        XCTAssertTrue(app.navigationBars["Unsorted"].appears(timeout: 5))
        waitForLabel(sample, containing: "1 of 10 answered")
    }
}
