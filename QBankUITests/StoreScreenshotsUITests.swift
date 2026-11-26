import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The App Store's screenshots, taken from the running app so they can be retaken after any change
/// (`test/store-screenshots.sh`, see `docs/app-store-screenshots/README.md`). A free account's first
/// launch with the sample set the app ships with, on the fake server and the fake store, in light:
/// nothing typed, no account's own questions and no real purchase. A unit test cannot do this job:
/// the pictures are of the real screens as the device draws them, status bar included.
///
/// Every picture is checked as it is taken: the device's full screen in pixels, a PNG with no alpha
/// channel, no keyboard, and unlike every picture before it. On a 6.9-inch iPhone and a 13-inch iPad
/// the full screen is the size App Store Connect asks for; asked to keep the pictures, the test
/// fails on any other device.
final class StoreScreenshotsUITests: XCTestCase {
    private let topic = "Getting started"
    private let folder = "Unsorted"
    private let set = "General knowledge sampler"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// The store set, in the order App Store Connect shows it by file name. On iPad the topic opens
    /// beside Home's list, so Home's picture shows the topic too and there is no separate one.
    @MainActor
    func testTheStoreSet() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        var camera = try StoreCamera(folder: isPad ? "ipad-13" : "iphone-6.9", storeSize: isPad ? .iPad13 : .iPhone69)
        let app = launchInLight("free-first-launch")

        let card = app.buttons["home.topic.\(topic)"]
        XCTAssertTrue(card.appears(timeout: 10))
        card.tap()
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        openFolder(app, folder)
        let sample = app.buttons["course.set.\(set)"]
        tapVisible(sample, in: app)
        XCTAssertTrue(app.buttons["practice.close"].appears(timeout: 5))

        // Question 1, its diagram and a choice picked, before Check answer.
        XCTAssertTrue(app.buttons["practice.image"].appears(timeout: 5))
        app.buttons["practice.option.1"].tap()
        waitForSelected(app.buttons["practice.option.1"])
        try take(&camera, "01-question", of: app)
        check(app)
        next(app)

        answer(app, [0])  // 2: true
        next(app)
        answer(app, [2])  // 3
        next(app)
        answer(app, [0, 2])  // 4: two of the three mammals, partly right
        next(app)
        answer(app, [3])  // 5
        next(app)
        answer(app, [0])  // 6: missed
        next(app)

        // Question 7 checked: the verdict, every choice, the rationale and the takeaway, which
        // together fit one iPhone screen.
        answer(app, [2])
        try take(&camera, "02-answer", of: app)
        next(app)

        answer(app, [0, 1, 4])  // 8
        next(app)
        answer(app, [0], isGuess: true)  // 9: right, flagged as a guess
        next(app)
        answer(app, [0])  // 10
        next(app)

        XCTAssertTrue(app.staticTexts["result.title"].appears(timeout: 10))
        XCTAssertEqual(app.staticTexts["result.title"].label, "8 of 10 fully right")
        if isPad {
            // An iPad has room to show one question opened where it is listed.
            app.buttons["result.question.4"].tap()
        }
        try take(&camera, "05-result", of: app)
        app.buttons["result.done"].tap()
        XCTAssertTrue(app.navigationBars[folder].appears(timeout: 5))
        goBack(app, from: folder)

        // The topic: its score, Exam, Review and Terms, and the set's folder on a page, so the
        // picture holds no empty list.
        XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        makePage(app, holding: folder)
        let review = app.buttons["course.tile.review"]
        waitForLabel(review, containing: "3")
        waitForLabel(app.descendants(matching: .any)["course.summary"], containing: "10 of 10 answered")
        // Home with the sample set's topic and how far it is answered, taken before the exam
        // answers change its counts.
        if !isPad {
            try take(&camera, "04-topic", of: app)
            goBack(app, from: topic)
            XCTAssertTrue(card.appears(timeout: 5))
        }
        try take(&camera, "03-home", of: app)
        if !isPad {
            card.tap()
            XCTAssertTrue(app.navigationBars[topic].appears(timeout: 5))
        }

        review.tap()
        XCTAssertTrue(app.navigationBars["Review"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["Practice these 3 (shuffled)"].appears(timeout: 5))
        try take(&camera, "06-review", of: app)
        goBack(app, from: "Review")

        app.buttons["course.tile.exam"].tap()
        XCTAssertTrue(app.navigationBars["Exam"].appears(timeout: 5))
        let pick = app.buttons["exam.folder.\(folder)"]
        tapVisible(pick, in: app)
        let start = app.buttons["exam.start"]
        reveal(start, in: app)
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: start)], timeout: 10), .completed)
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["exam.timer"].appears(timeout: 10))
        // An exam draws its questions in no fixed order: answer up to the one about the oceans.
        answerExam(app, upTo: "The Earth's surface")
        let choice = app.buttons["practice.option.3"]
        tapVisible(choice, in: app)
        waitForSelected(choice)
        // Its timer never stops, so the screen counts as still once everything under it is.
        try take(&camera, "07-exam", of: app, changingAbove: app.descendants(matching: .any)["exam.timer"])
    }

    /// The subscription's review screenshot: the plans sheet with each plan's name, period and
    /// price, the renewal terms, the two policy links and Restore purchases, all on one screen.
    /// App Review asks for one picture, so it is taken on iPhone only.
    @MainActor
    func testTheCloudPlansSheet() throws {
        try skipOnIPad()
        var camera = try StoreCamera(folder: "review", storeSize: .iPhone69)
        let app = launchInLight("free-first-launch")

        XCTAssertTrue(app.buttons["home.add"].appears(timeout: 10))
        openTab(app, "Settings")
        let cloud = app.buttons["settings.cloud"]
        XCTAssertTrue(cloud.appears(timeout: 5))
        waitForLabel(cloud, containing: "Off")
        cloud.tap()
        XCTAssertTrue(app.navigationBars["QBank Cloud"].appears(timeout: 5))
        for plan in ["monthly", "yearly"] {
            XCTAssertTrue(app.staticTexts["cloud.plan.\(plan).price"].appears(timeout: 5), plan)
        }
        for id in ["cloud.autoRenew", "cloud.privacy", "cloud.terms", "cloud.restore"] {
            let element = app.descendants(matching: .any)[id]
            XCTAssertTrue(element.appears(timeout: 5), id)
            // A smaller iPhone scrolls to the last of them.
            if camera.isStoreScreen {
                XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame), "\(id) is off the screen")
            }
        }
        try take(&camera, "cloud-plans", of: app)
    }

    /// Launches in light whatever the device's own appearance is.
    @MainActor
    private func launchInLight(_ scenario: String) -> XCUIApplication {
        let app = launch(scenario)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        postDebugNotification("com.dimitrygallego.qbank.uitest.look.light")
        return app
    }

    /// Picks the choices, checks the answer and waits for its verdict.
    @MainActor
    private func answer(_ app: XCUIApplication, _ options: [Int], isGuess: Bool = false) {
        XCTAssertTrue(app.buttons["practice.check"].appears(timeout: 5))
        for option in options {
            tapVisible(app.buttons["practice.option.\(option)"], in: app)
        }
        if isGuess {
            tapVisible(app.switches["practice.guess"], in: app)
        }
        check(app)
    }

    @MainActor
    private func check(_ app: XCUIApplication) {
        app.buttons["practice.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].appears(timeout: 5))
    }

    /// Next question, or See results after the last one.
    @MainActor
    private func next(_ app: XCUIApplication) {
        let button = app.buttons["practice.next"]
        XCTAssertTrue(button.appears(timeout: 5))
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["practice.feedback"].disappears(timeout: 5))
    }

    /// Makes the topic's first page with the folder on it, under the name the app offers, and
    /// comes back to the topic.
    @MainActor
    private func makePage(_ app: XCUIApplication, holding folder: String) {
        app.buttons["course.add"].tap()
        chooseFromMenu(menuItem(app, "course.add.page", "New page"))
        let chip = app.buttons["editPage.chip.free.\(folder)"]
        tapWhenStill(chip)
        app.buttons["editPage.save"].tap()
        XCTAssertTrue(app.navigationBars["Page 1"].appears(timeout: 10))
        goBack(app, from: "Page 1")
        XCTAssertTrue(app.buttons["course.page.Page 1"].appears(timeout: 5))
    }

    /// Submits the exam's questions, each with one choice picked, until the one whose stem starts
    /// this way is up. An exam says nothing about an answer before it ends.
    @MainActor
    private func answerExam(_ app: XCUIApplication, upTo start: String) {
        let count = app.staticTexts["practice.count"]
        for number in 1...10 {
            waitForLabel(count, containing: "\(number) of 10")
            let stem = app.staticTexts["practice.stem"]
            XCTAssertTrue(stem.appears(timeout: 5))
            if stem.label.hasPrefix(start) { return }
            tapVisible(app.buttons["practice.option.0"], in: app)
            app.buttons["exam.submit"].tap()
        }
        XCTFail("no question starts \"\(start)\"")
    }

    /// Takes the screen once it has stopped changing, checks the picture, keeps it in the test
    /// results, and writes it out when the run asked for the pictures.
    @MainActor
    private func take(_ camera: inout StoreCamera, _ name: String, of app: XCUIApplication, changingAbove element: XCUIElement? = nil) throws {
        XCTAssertEqual(app.keyboards.count, 0, "\(name): a keyboard shows")
        XCTAssertFalse(app.descendants(matching: .any)["problem"].exists, "\(name): a problem shows")
        let changing = element.map { Double($0.frame.maxY / app.windows.firstMatch.frame.height) }
        let picture = try camera.take(name, changingAbove: changing)
        let attachment = XCTAttachment(data: picture, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "\(camera.folder) \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Takes one folder of store pictures and holds each to what App Store Connect accepts.
private struct StoreCamera {
    /// A screenshot size App Store Connect asks for, in pixels, portrait.
    struct Size: Equatable, CustomStringConvertible {
        let width: Int
        let height: Int

        static let iPhone69 = Size(width: 1320, height: 2868)
        static let iPad13 = Size(width: 2064, height: 2752)

        var description: String { "\(width) x \(height)" }
    }

    /// The folder under the output folder: one per set App Store Connect takes.
    let folder: String
    /// The size every picture has: the store's when the pictures are kept, and otherwise the
    /// screen of the device the test runs on.
    private let size: Size
    /// Whether this device's screen is the size App Store Connect asks for.
    let isStoreScreen: Bool
    /// Where the pictures are written, when the run asked for them.
    private let output: URL?
    /// The pixels under the status bar of every picture taken, by name.
    private var taken: [(name: String, pixels: Data)] = []

    /// `STORE_SCREENSHOTS_DIR`, which `test/store-screenshots.sh` sets, is a folder of the Mac the
    /// simulator runs on.
    init(folder: String, storeSize: Size) throws {
        let environment = ProcessInfo.processInfo.environment
        let screen = Size(
            width: try XCTUnwrap(environment["SIMULATOR_MAINSCREEN_WIDTH"].flatMap { Int($0) }, "runs on a simulator"),
            height: try XCTUnwrap(environment["SIMULATOR_MAINSCREEN_HEIGHT"].flatMap { Int($0) }, "runs on a simulator")
        )
        self.folder = folder
        output = environment["STORE_SCREENSHOTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(folder, isDirectory: true) }
        if output != nil {
            XCTAssertEqual(screen, storeSize, "the \(folder) pictures are taken on a \(storeSize) screen")
        }
        size = output == nil ? screen : storeSize
        isStoreScreen = screen == storeSize
    }

    /// How much of the screen's height the status bar, where the clock runs, is within.
    private static let statusBar = 0.05

    /// - Parameter changingAbove: How far down the screen, as a share of its height, something
    ///   never stops changing, if anything below the status bar does.
    @MainActor
    mutating func take(_ name: String, changingAbove: Double?) throws -> Data {
        let image = try settledScreen(name, below: max(Self.statusBar, changingAbove ?? 0))
        let picture = try Self.opaquePNG(image)
        try expectStorePNG(picture, name: name)
        let pixels = try Self.pixels(of: image, below: Self.statusBar)
        for earlier in taken {
            XCTAssertGreaterThan(Self.share(of: pixels, differingFrom: earlier.pixels), 0.005, "\(name) shows the same screen as \(earlier.name)")
        }
        taken.append((name, pixels))
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try picture.write(to: output.appendingPathComponent("\(name).png"))
        }
        return picture
    }

    /// The screen once two looks half a second apart are the same below `share` of its height, so
    /// no transition, highlight or scroll bar is caught on its way.
    @MainActor
    private func settledScreen(_ name: String, below share: Double) throws -> CGImage {
        var last: Data?
        for _ in 0..<20 {
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
            // The screen's, not the app's: an iPad app's own screenshot comes out turned and cut.
            let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
            let pixels = try Self.pixels(of: image, below: share)
            if pixels == last { return image }
            last = pixels
        }
        throw Failure(description: "\(name): the screen never stopped changing")
    }

    /// A PNG's header says its size, bit depth and color type; type 2 is red, green and blue with no
    /// alpha channel.
    private func expectStorePNG(_ picture: Data, name: String) throws {
        let bytes = [UInt8](picture.prefix(26))
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "\(name) is not a PNG")
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(Size(width: width, height: height), size, "\(name) has the wrong size")
        XCTAssertEqual(bytes[24], 8, "\(name) is not 8 bits a channel")
        XCTAssertEqual(bytes[25], 2, "\(name) has an alpha channel or is not in color")
        XCTAssertNil(picture.range(of: Data("tRNS".utf8)), "\(name) has transparency")
    }

    /// The picture drawn into sRGB with nowhere to put alpha.
    private static func opaquePNG(_ image: CGImage) throws -> Data {
        let opaque = try XCTUnwrap(context(width: image.width, height: image.height).draw(image).makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, opaque, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The picture's pixels below `share` of its height.
    private static func pixels(of image: CGImage, below share: Double) throws -> Data {
        let top = Int(Double(image.height) * share)
        let below = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top)))
        let drawn = try context(width: below.width, height: below.height).draw(below)
        let bytes = try XCTUnwrap(drawn.data)
        return Data(bytes: bytes, count: drawn.bytesPerRow * drawn.height)
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
    }

    /// The share of pixels that differ between two pictures of one screen size.
    private static func share(of one: Data, differingFrom other: Data) -> Double {
        guard one.count == other.count else { return 1 }
        let differing = one.withUnsafeBytes { first in
            other.withUnsafeBytes { second in
                zip(first.bindMemory(to: UInt32.self), second.bindMemory(to: UInt32.self)).count { $0 != $1 }
            }
        }
        return Double(differing) / Double(one.count / 4)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
}

private extension CGContext {
    /// Draws the picture over the whole context and gives the context back.
    func draw(_ image: CGImage) -> CGContext {
        draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return self
    }
}
