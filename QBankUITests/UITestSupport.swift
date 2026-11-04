import XCTest

extension XCTestCase {
    /// Launches the real app in a scenario of the Debug launch seam (`QB_UITEST_SCENARIO`).
    /// `keepPhoneSettings` keeps the settings an earlier launch saved on the phone, and
    /// `keepPhoneData` the courses it saved and the answers it left waiting. `online: false`
    /// starts without a network. `deviceOwner` is how the device answers the Face ID lock, such as
    /// `face-id` (`QB_UITEST_DEVICE_OWNER`); every launch gets a fake, so the simulator's own
    /// Face ID never plays a part.
    @MainActor
    func launch(
        _ scenario: String,
        keepPhoneSettings: Bool = false,
        keepPhoneData: Bool = false,
        online: Bool = true,
        deviceOwner: String = "face-id"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["QB_UITEST_SCENARIO"] = scenario
        app.launchEnvironment["QB_UITEST_DEVICE_OWNER"] = deviceOwner
        if keepPhoneSettings {
            app.launchEnvironment["QB_UITEST_KEEP_PHONE_SETTINGS"] = "1"
        }
        if keepPhoneData {
            app.launchEnvironment["QB_UITEST_KEEP_PHONE_DATA"] = "1"
        }
        if !online {
            app.launchEnvironment["QB_UITEST_NETWORK"] = "offline"
        }
        app.launch()
        return app
    }

    /// Skips a test that walks the iPhone layout, where a course opens over Home; on iPad it opens
    /// beside the list, and `IPadUITests` walks that.
    @MainActor
    func skipOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "walks the iPhone layout; IPadUITests covers the iPad's")
    }

    /// Turns the fake server's network off or on while the app runs, through the Darwin
    /// notifications `DebugLaunchScenario` names, and waits until the app says it has. The
    /// notification reaches the app a moment later, and on a busy Mac an answer checked at once
    /// could still reach QBank.
    func setNetwork(online: Bool) {
        let name = online ? "com.dimitrygallego.qbank.uitest.network.online" : "com.dimitrygallego.qbank.uitest.network.offline"
        let applied = XCTDarwinNotificationExpectation(notificationName: name + ".applied")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 10), .completed, "the app never went \(online ? "online" : "offline")")
    }

    /// Makes the fake device confirm her at the next Face ID check, or refuse as though she
    /// cancelled, through the Darwin notifications `DebugLaunchScenario` names.
    func setDeviceOwner(confirms: Bool) {
        let name = confirms ? "com.dimitrygallego.qbank.uitest.owner.confirms" : "com.dimitrygallego.qbank.uitest.owner.refuses"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Opens another window of the app on iPad, as she can from the Dock, through the Darwin
    /// notification `DebugLaunchScenario` names.
    func openAnotherWindow() {
        let name = "com.dimitrygallego.qbank.uitest.window.new"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Keeps a screenshot in the test results, for comparing the screens with the wireframes.
    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        // The screen's, not the app's: an iPad app's own screenshot comes out turned and cut in landscape.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Keeps a screenshot in light and in dark, as she sees the screen after choosing Light or
    /// Dark in Settings, then goes back to Match device. The Look is set through the Darwin
    /// notifications `DebugLaunchScenario.lookNotification(_:)` names.
    @MainActor
    func attachLooks(_ app: XCUIApplication, _ name: String) {
        for look in ["light", "dark"] {
            setLook(look)
            attach(app, "\(name) \(look)")
        }
        setLook("auto")
    }

    /// Sets the app's Look, `light`, `dark`, or `auto`, and gives the screen a moment to redraw
    /// in its colors and to finish any animation.
    @MainActor
    private func setLook(_ look: String) {
        let name = "com.dimitrygallego.qbank.uitest.look.\(look)"
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
        RunLoop.current.run(until: .now.addingTimeInterval(1))
    }

    /// Waits until the element's label contains the text. It looks once at once, because XCTest's
    /// own wait looks first a second later, and a line shown for a few seconds can be gone by then.
    @MainActor
    func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) {
        if let now = try? element.snapshot(), now.label.contains(text) { return }
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\"\(element.label)\" never contained \"\(text)\"")
    }

    /// Taps a button once it stops moving, as one in a sheet does when the sheet settles at its
    /// height. A tap made while it moves can land beside it.
    @MainActor
    func tapWhenStill(_ element: XCUIElement) {
        waitUntilStill(element)
        element.tap()
    }

    /// Waits until the element has stopped moving and can be touched, for at most three seconds.
    /// A sheet's button can report where it will settle while the sheet still slides in.
    @MainActor
    func waitUntilStill(_ element: XCUIElement) {
        XCTAssertTrue(element.appears(timeout: 5))
        var frame = element.frame
        for _ in 0..<20 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            let now = element.frame
            if now == frame, element.isHittable { break }
            frame = now
        }
    }

    /// An item of the menu that is open, such as a + menu or the one holding a card opens, with
    /// this identifier and this title. iOS 27.2 drops the identifiers of the items in a + menu's
    /// section and labels each with its title, a comma and its subtitle; iOS 26.5 keeps the
    /// identifier and labels it with the title alone. So the item must have the title, and the
    /// identifier wherever iOS keeps one.
    @MainActor
    func menuItem(_ app: XCUIApplication, _ identifier: String, _ title: String) -> XCUIElement {
        let item = NSPredicate(
            format: "(identifier == %@ OR identifier == '') AND (label == %@ OR label BEGINSWITH %@)",
            identifier, title, title + ", "
        )
        return app.collectionViews.cells.buttons.matching(item).firstMatch
    }

    /// Chooses an item of the context menu that touch and hold opened, such as Delete, and waits
    /// until the menu has closed. On a busy Mac the menu now and then drops a tap that reached the
    /// item: the item lights up, its action does not run, and the menu stays open. The menu
    /// closing is the sign the choice was taken; while it stays open, she chooses again.
    @MainActor
    func chooseFromMenu(_ item: XCUIElement) {
        XCTAssertTrue(item.appears(timeout: 5))
        for _ in 0..<3 {
            item.tap()
            if item.disappears(timeout: 5) { return }
        }
        XCTFail("The menu stayed open after choosing \(item.label)")
    }

    /// Taps a row that opens a screen until the screen titled `title` is up. On a busy Mac a tap
    /// on a screen she just stepped back to is now and then dropped: the row does not light up
    /// and nothing opens.
    @MainActor
    func open(_ row: XCUIElement, titled title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        for _ in 0..<3 {
            tapVisible(row, in: app)
            if bar.appears(timeout: 5) { return }
        }
        XCTFail("\(title) did not open")
    }

    /// Scrolls until the element is on screen, clear of the bars at the top and bottom, then taps it.
    @MainActor
    func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.tap()
    }

    /// Scrolls until the element is on screen, clear of the bars at the top and bottom.
    @MainActor
    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.appears(timeout: 5))
        let window = app.windows.firstMatch.frame
        for _ in 0..<10 {
            let frame = element.frame
            if element.isHittable, frame.minY > window.minY + 120, frame.maxY < window.maxY - 120 { return }
            if frame.midY > window.midY {
                app.swipeUp(velocity: .slow)
            } else {
                app.swipeDown(velocity: .slow)
            }
        }
    }

    /// A tab's button: in the tab bar at the bottom on iPhone, or at the top on iPad, whose tabs are
    /// plain buttons ahead of everything else on screen.
    @MainActor
    func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        UIDevice.current.userInterfaceIdiom == .pad ? app.buttons[name].firstMatch : app.tabBars.buttons[name]
    }

    @MainActor
    func openTab(_ app: XCUIApplication, _ name: String, timeout: TimeInterval = 5) {
        let tab = tabButton(app, name)
        XCTAssertTrue(tab.appears(timeout: timeout))
        tab.tap()
    }

    /// Steps back from the screen titled `title`, and waits until it has gone, so the next tap
    /// lands on the screen underneath and not on one still sliding in. A tap made while the screen
    /// is still settling can go unanswered, so it taps again while the screen stays.
    @MainActor
    func goBack(_ app: XCUIApplication, from title: String) {
        let bar = app.navigationBars[title]
        for _ in 0..<3 {
            bar.buttons.firstMatch.tap()
            if bar.disappears(timeout: 5) { return }
        }
        XCTFail("still on \(title)")
    }

    /// Fills the sign-in form and presses Sign in. A nil email keeps what is in the field.
    @MainActor
    func signIn(_ app: XCUIApplication, email: String?, password: String) {
        if let email {
            let field = app.textFields["signIn.email"]
            focus(field, in: app)
            field.typeText(email)
        }
        let field = app.secureTextFields["signIn.password"]
        focus(field, in: app)
        field.typeText(password)
        app.buttons["signIn.submit"].tap()
    }

    /// Taps a field until it has the keyboard. iOS can offer to save the password a second time
    /// once the first offer is gone, and that late offer takes the keyboard from the field.
    @MainActor
    func focus(_ field: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            field.tap()
            if field.value(forKey: "hasKeyboardFocus") as? Bool == true { return }
            let notNow = app.buttons["Not Now"]
            if notNow.appears(timeout: 2) {
                tapWhenStill(notNow)
                _ = notNow.disappears(timeout: 3)
            }
        }
        XCTFail("\(field) never got the keyboard")
    }

    /// iOS offers to save the password after a sign-in; the tests decline, as she may. On GitHub's
    /// Mac the offer has come as late as five and a half seconds after Sign in.
    @MainActor
    func dismissSavePassword(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        guard notNow.appears(timeout: 10) else { return }
        // A tap while the prompt is still animating in does not register: tap until it is gone.
        for _ in 0..<5 {
            if notNow.isHittable { notNow.tap() }
            if notNow.disappears(timeout: 2) { return }
        }
        XCTFail("The Save Password prompt did not go away")
    }

    /// QBank signs in with a password only: nothing on screen offers, lists, or names a passkey.
    @MainActor
    func expectNoPasskeys(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let passkeys = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'passkey' OR identifier CONTAINS[c] 'passkey'"))
        XCTAssertEqual(passkeys.count, 0, "something names a passkey", file: file, line: line)
    }

    /// Puts text in the Paste JSON field the way she does: from the pasteboard, with Paste.
    @MainActor
    func paste(_ text: String, in app: XCUIApplication) {
        if !app.textViews["import.paste"].exists {
            app.buttons["Paste JSON"].tap()
        }
        let editor = app.textViews["import.paste"]
        XCTAssertTrue(editor.appears(timeout: 5))
        UIPasteboard.general.string = text
        reveal(editor, in: app)
        editor.tap()
        let paste = app.menuItems["Paste"]
        if !paste.appears(timeout: 2) {
            editor.tap()
        }
        XCTAssertTrue(paste.appears(timeout: 5))
        paste.tap()
        waitForLabel(editor, valueContaining: "\"questions\"")
        // The keyboard covers the buttons below. An iPad's has a key that hides it, and there a
        // swipe down would close the sheet the field can be in.
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists {
            hide.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    @MainActor
    func waitForLabel(_ element: XCUIElement, valueContaining text: String, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let result = XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "the field never held \(text)")
    }

    /// Opens a folder from the course page, through its exam page when it is on one.
    @MainActor
    func openFolder(_ app: XCUIApplication, _ name: String, on page: String? = nil) {
        if let page {
            open(app.buttons["course.page.\(page)"], titled: page, in: app)
        }
        open(app.buttons["folder.\(name)"], titled: name, in: app)
    }
}

extension XCUIElement {
    /// `waitForExistence(timeout:)`, but true at once for an element already on screen. XCTest's
    /// own wait takes its first look only after a second, even then, and over the suite's hundreds
    /// of waits those seconds added up to a third of the UI tests' time on GitHub's Mac.
    @MainActor
    func appears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }

    /// `waitForNonExistence(timeout:)`, but true at once for an element already gone.
    @MainActor
    func disappears(timeout: TimeInterval) -> Bool {
        !exists || waitForNonExistence(timeout: timeout)
    }

    /// Deletes what the field holds, from its end.
    @MainActor
    func clearText() {
        tap()
        let current = value as? String ?? ""
        let placeholder = placeholderValue ?? ""
        guard !current.isEmpty, current != placeholder else { return }
        coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
}
