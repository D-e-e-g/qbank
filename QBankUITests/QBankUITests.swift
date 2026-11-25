import XCTest

/// Slices 1a and 1d end to end: the real app against the in-process fake server of the Debug launch seam.
/// Invented accounts only, never a real one, never the production server.
final class QBankUITests: XCTestCase {
    private static let email = "student@example.com"
    private static let password = "synthetic-pass-1"

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        try skipOnIPad()
    }

    @MainActor
    func testSignInLandsOnHerLastCourseAndSignsOut() throws {
        let app = launch("signed-out")
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        expectNoPasskeys(app)
        attach(app, "1a-1 sign in")

        signIn(app, email: Self.email, password: "not-the-password")
        let problem = app.staticTexts["That email or password is not right."]
        XCTAssertTrue(problem.appears(timeout: 5))
        dismissKeyboard(app)
        attach(app, "1a-1 sign in, wrong password")

        signIn(app, email: nil, password: Self.password)
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10), "lands on the course she used last")
        expectNoPasskeys(app)
        XCTAssertTrue(app.buttons["course.page.Exam 1"].appears(timeout: 5))
        let summary = app.descendants(matching: .any)["course.summary"]
        XCTAssertTrue(summary.label.hasPrefix("Mental Health · 86 questions · 4 folders"), summary.label)
        attach(app, "1a-4 course")

        let back = app.navigationBars["NURS 310"].buttons["Home"]
        XCTAssertTrue(back.appears(timeout: 5))
        back.tap()
        XCTAssertTrue(app.navigationBars["Home"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["home.course.NURS 310"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["home.course.NURS 220"].exists)
        XCTAssertTrue(app.staticTexts["No courses yet. Tap + to add one, or import its first question file."].exists)
        attach(app, "1a-3 home")

        app.buttons["home.course.NURS 220"].tap()
        XCTAssertTrue(app.navigationBars["NURS 220"].appears(timeout: 5))
        app.navigationBars["NURS 220"].buttons["Home"].tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts[Self.email].appears(timeout: 5))
        XCTAssertTrue(app.buttons["settings.changePassword"].exists)
        expectNoPasskeys(app)
        attach(app, "1d settings (sign out)")

        app.buttons["settings.signOut"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
    }

    @MainActor
    func testTemporaryPasswordAsksForANewOneFirst() throws {
        let app = launch("signed-out")
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        signIn(app, email: "reset@example.com", password: "synthetic-temp-1")

        XCTAssertTrue(app.staticTexts["choosePassword.title"].appears(timeout: 10))
        dismissSavePassword(app)
        let newPassword = app.secureTextFields["choosePassword.new"]
        XCTAssertTrue(newPassword.appears(timeout: 5))
        dismissKeyboard(app)
        attach(app, "1a-2 choose a new password")

        focus(newPassword, in: app)
        newPassword.typeText("short")
        app.buttons["choosePassword.save"].tap()
        XCTAssertTrue(app.staticTexts["Choose a password of at least 8 characters."].appears(timeout: 5))

        focus(newPassword, in: app)
        newPassword.typeText("-and-longer")
        app.buttons["choosePassword.save"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        expectNoPasskeys(app)
    }

    /// Sign up from the sign-in screen with the email the owner added: a refused email says why,
    /// "I have an account" goes back, and the new account lands signed in.
    @MainActor
    func testSignUpMakesAUserAccountForTheListedEmail() throws {
        let app = launch("signed-out")
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        app.buttons["signIn.signUp"].tap()
        XCTAssertTrue(app.staticTexts["signUp.title"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["Make a user account with an email the owner has added."].exists)
        XCTAssertTrue(app.staticTexts["At least 8 characters."].exists)
        attachLooks(app, "1a-5 sign up")

        let email = app.textFields["signUp.email"]
        let password = app.secureTextFields["signUp.password"]
        focus(email, in: app)
        email.typeText("stranger@example.com")
        focusNewPassword(password, in: app)
        password.typeText("synthetic-pass-9")
        app.buttons["signUp.submit"].tap()
        XCTAssertTrue(app.staticTexts["This email can't sign up here. If you already have an account, sign in. Otherwise, ask the owner to add your email."].appears(timeout: 5))
        dismissKeyboard(app)
        attach(app, "1a-5 sign up, refused")

        app.buttons["signUp.signIn"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 5))
        app.buttons["signIn.signUp"].tap()
        XCTAssertTrue(app.staticTexts["signUp.title"].appears(timeout: 5))
        XCTAssertEqual(email.value as? String, "Email", "a fresh form")

        focus(email, in: app)
        email.typeText("new.user@example.com")
        focusNewPassword(password, in: app)
        password.typeText("short")
        app.buttons["signUp.submit"].tap()
        XCTAssertTrue(app.staticTexts["Choose a password of at least 8 characters."].appears(timeout: 5))
        focusNewPassword(password, in: app)
        password.typeText("-and-longer")
        app.buttons["signUp.submit"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        expectNoPasskeys(app)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["new.user@example.com"].appears(timeout: 5), "signed in as the new account")
    }

    @MainActor
    func testRestoreAsksFirstThenBringsBackThePreviousVersion() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        openFolder(app, "Week 2", on: "Exam 1")
        let restore = app.buttons["course.restore"]
        reveal(restore, in: app)
        XCTAssertTrue(app.staticTexts["Replaced \(Self.shortDate(daysAgo: 6)) · 12 questions"].exists)
        restore.tap()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.appears(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["Restore the previous “Psychosocial Assessment and Safety Screening”?"].exists)
        attach(app, "1a-4 restore asks first")
        sheet.buttons["Restore"].tap()

        XCTAssertTrue(app.staticTexts["Restored today · 12 questions"].appears(timeout: 5))
        XCTAssertFalse(app.staticTexts["That set is not the current version."].exists)
    }

    @MainActor
    func testTilesOpenExamReviewAndTerms() throws {
        let app = launch("signed-in")
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        for (tile, title) in [("exam", "Exam"), ("review", "Review"), ("terms", "Terms")] {
            app.buttons["course.tile.\(tile)"].tap()
            XCTAssertTrue(app.navigationBars[title].appears(timeout: 5), title)
            goBack(app, from: title)
            XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 5))
        }
    }

    // MARK: Settings (slice 1d)

    @MainActor
    func testLookIsKeptOnThePhone() throws {
        let app = launch("signed-in")
        openSettings(app)
        let matchDevice = app.buttons["Match device"]
        XCTAssertTrue(matchDevice.appears(timeout: 5))
        XCTAssertTrue(matchDevice.isSelected, "Match device is the first choice")
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.buttons["Dark"].isSelected)
        XCTAssertFalse(matchDevice.isSelected)

        app.terminate()
        let again = launch("signed-in", keepPhoneSettings: true)
        openSettings(again)
        XCTAssertTrue(again.buttons["Dark"].appears(timeout: 5))
        XCTAssertTrue(again.buttons["Dark"].isSelected, "Dark survives a relaunch")
        again.buttons["Match device"].tap()
        XCTAssertTrue(again.buttons["Match device"].isSelected)
    }

    /// Color is the account's: Slate shows at once, a pick without signal goes back and says why,
    /// and signing in again reads it from her account on the server.
    @MainActor
    func testColorGoesWithHerAccount() throws {
        let app = launch("signed-in")
        openSettings(app)
        let dusk = app.buttons["Dusk"]
        let slate = app.buttons["Slate"]
        XCTAssertTrue(dusk.appears(timeout: 5))
        reveal(slate, in: app)
        XCTAssertTrue(dusk.isSelected, "every account starts on Dusk")
        XCTAssertFalse(slate.isSelected)
        attach(app, "color, dusk")
        slate.tap()
        XCTAssertTrue(slate.isSelected)
        XCTAssertFalse(dusk.isSelected)
        XCTAssertTrue(app.buttons["Match device"].isSelected, "Look stays as it was")
        attachLooks(app, "color, slate")

        setNetwork(online: false)
        dusk.tap()
        let problem = app.staticTexts["No connection. Check Wi-Fi or cellular data and try again."]
        XCTAssertTrue(problem.appears(timeout: 5))
        XCTAssertTrue(slate.isSelected, "the pick went back to Slate")
        attach(app, "color, not saved offline")
        setNetwork(online: true)

        app.swipeDown()
        app.buttons["settings.signOut"].tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        attach(app, "color, signed out in dusk")
        signIn(app, email: Self.email, password: Self.password)
        dismissSavePassword(app)
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        attachLooks(app, "color, course in slate")
        app.tabBars.buttons["Settings"].tap()
        reveal(slate, in: app)
        XCTAssertTrue(slate.isSelected, "her account kept Slate")
        XCTAssertFalse(problem.exists)

        dusk.tap()
        XCTAssertTrue(dusk.isSelected)
        XCTAssertFalse(slate.isSelected)
    }

    @MainActor
    func testChangePasswordExplainsEachRefusal() throws {
        let app = launch("signed-in")
        openSettings(app)
        app.buttons["settings.changePassword"].tap()
        let current = app.secureTextFields["changePassword.current"]
        let new = app.secureTextFields["changePassword.new"]
        XCTAssertTrue(current.appears(timeout: 5))

        app.buttons["changePassword.save"].tap()
        XCTAssertTrue(app.staticTexts["Enter your current password and a new one."].appears(timeout: 5))

        type(current, "not-it")
        type(new, "short")
        app.buttons["changePassword.save"].tap()
        XCTAssertTrue(app.staticTexts["Choose a password of at least 8 characters."].appears(timeout: 5))

        type(new, "-and-longer")
        app.buttons["changePassword.save"].tap()
        XCTAssertTrue(app.staticTexts["That password is not right."].appears(timeout: 5))
        let left = current.value as? String ?? ""
        XCTAssertTrue(left.isEmpty || left == current.placeholderValue, "the wrong current password is cleared, not \(left)")

        type(current, Self.password)
        app.buttons["changePassword.save"].tap()
        dismissSavePassword(app)
        XCTAssertTrue(app.staticTexts["Password saved."].appears(timeout: 5))
        attach(app, "1d-2 change password, saved")
        XCTAssertTrue(app.navigationBars["Change password"].exists, "still signed in, on the same screen")

        app.navigationBars["Change password"].buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts[Self.email].appears(timeout: 5))
    }

    /// Delete account says what goes for good and asks for her password; a wrong one deletes
    /// nothing, and the right one signs her out of an account that no longer signs in.
    @MainActor
    func testDeleteAccountAsksForHerPasswordThenSignsHerOut() throws {
        let app = launch("signed-in")
        openSettings(app)
        let row = app.buttons["settings.deleteAccount"]
        XCTAssertTrue(row.appears(timeout: 5))
        attach(app, "1d settings, delete account row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Delete account"].appears(timeout: 5))
        let message = app.staticTexts["deleteAccount.message"]
        XCTAssertTrue(message.label.contains("deleted for good"), message.label)
        XCTAssertTrue(message.label.contains("there is no Undo"), message.label)
        attachLooks(app, "1d-4 delete account")

        let delete = app.buttons["deleteAccount.delete"]
        delete.tap()
        XCTAssertTrue(app.staticTexts["Enter your password to delete your account."].appears(timeout: 5))

        let password = app.secureTextFields["deleteAccount.password"]
        type(password, "not-it")
        delete.tap()
        XCTAssertTrue(app.staticTexts["That password is not right."].appears(timeout: 5))
        dismissKeyboard(app)
        attach(app, "1d-4 delete account, wrong password")
        XCTAssertTrue(app.navigationBars["Delete account"].exists, "still signed in, on the same screen")

        type(password, Self.password)
        delete.tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].appears(timeout: 10))
        dismissSavePassword(app)

        signIn(app, email: Self.email, password: Self.password)
        XCTAssertTrue(app.staticTexts["That email or password is not right."].appears(timeout: 5), "the deleted account signs in no more")
    }

    @MainActor
    func testSettingsKeepsSemestersForTheirNameAndDates() throws {
        let app = launch("signed-in")
        openSettings(app)
        let semesterOne = app.buttons["settings.semester.1"]
        XCTAssertTrue(semesterOne.appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["NURS 310, NURS 220"].exists)

        // Adding lives on Home's + now, and holding a course there renames, moves or archives it.
        XCTAssertFalse(app.buttons["settings.addSemester"].exists)
        XCTAssertFalse(app.staticTexts["Study topics"].exists)
        XCTAssertFalse(app.textFields["settings.newTopicName"].exists)
        XCTAssertTrue(app.staticTexts["Open a semester for its name and dates. Add from Home's +; rename, move or archive a course by holding it on Home."].exists)
        attach(app, "A-4 settings")

        // Rename Semester 1 and give it a start date.
        semesterOne.tap()
        let name = app.textFields["semester.name"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.clearAndType("Fall 2026")
        app.buttons["semester.starts.add"].tap()
        XCTAssertTrue(app.buttons["semester.starts.clear"].appears(timeout: 5))
        app.buttons["semester.save"].tap()
        XCTAssertTrue(app.staticTexts["Saved."].appears(timeout: 5))
        XCTAssertTrue(app.navigationBars["Fall 2026"].appears(timeout: 5))
        XCTAssertFalse(app.textFields["semester.newCode"].exists, "a course is added from Home's +")
        XCTAssertTrue(app.buttons["semester.archive"].exists)
        app.navigationBars["Fall 2026"].buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["NURS 310, NURS 220"].appears(timeout: 5))

        app.tabBars.buttons["Home"].tap()
        if app.navigationBars["NURS 310"].exists {
            app.navigationBars["NURS 310"].buttons["Home"].tap()
        }
        XCTAssertTrue(app.buttons["home.course.NURS 220"].appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["FALL 2026"].exists || app.staticTexts["Fall 2026"].exists)
    }

    /// Every Settings screen in Light and in Dark, kept as screenshots to compare with the
    /// approved wireframes.
    @MainActor
    func testSettingsScreensInLightAndDark() throws {
        let app = launch("signed-in")
        openSettings(app)
        for look in ["Light", "Dark"] {
            let tag = look.lowercased()
            app.buttons[look].tap()
            XCTAssertTrue(app.buttons[look].isSelected)
            app.swipeDown()
            attach(app, "1d-1 settings, \(tag)")
            scroll(app, until: app.staticTexts["settings.version"])
            attach(app, "1d-1 settings scrolled, \(tag)")

            open(app.buttons["settings.changePassword"], titled: "Change password", in: app)
            XCTAssertTrue(app.secureTextFields["changePassword.current"].appears(timeout: 5))
            attach(app, "1d-2 change password, \(tag)")
            app.buttons["changePassword.save"].tap()
            XCTAssertTrue(app.staticTexts["Enter your current password and a new one."].appears(timeout: 5))
            attach(app, "1d-2 change password, problem, \(tag)")
            app.navigationBars["Change password"].buttons["Settings"].tap()

            open(app.buttons["settings.semester.1"], titled: "Semester 1", in: app)
            XCTAssertTrue(app.textFields["semester.name"].appears(timeout: 5))
            app.buttons["semester.starts.add"].tap()
            XCTAssertTrue(app.buttons["semester.starts.clear"].appears(timeout: 5))
            attach(app, "1d-3 semester, \(tag)")
            app.navigationBars["Semester 1"].buttons["Settings"].tap()
            XCTAssertTrue(app.buttons[look].appears(timeout: 5))
        }
    }

    // MARK: Helpers

    /// The signed-in scenario opens her last course; Settings is one tab away.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["NURS 310"].appears(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].appears(timeout: 5))
    }

    /// Swipes up until `element` is on screen and clear of the tab bar. A swipe made while the
    /// previous screen is still settling can be lost, so it tries again.
    @MainActor
    private func scroll(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 0..<4 {
            app.swipeUp()
            if element.isHittable, element.frame.maxY < app.tabBars.firstMatch.frame.minY { return }
        }
        XCTFail("\(element) did not scroll into view")
    }

    @MainActor
    private func type(_ field: XCUIElement, _ text: String) {
        field.tap()
        field.typeText(text)
    }

    /// Focuses a new-password field. iOS offers a strong password there, in a sheet over the
    /// keyboard; the tests close it and type their own, as she may.
    @MainActor
    private func focusNewPassword(_ field: XCUIElement, in app: XCUIApplication) {
        focus(field, in: app)
        let offer = app.staticTexts["Use Strong Password?"]
        guard offer.appears(timeout: 3) else { return }
        let close = app.buttons["Close"]
        XCTAssertTrue(close.appears(timeout: 2), app.debugDescription)
        tapWhenStill(close)
        XCTAssertTrue(offer.disappears(timeout: 3), "the strong password offer stayed")
        if field.value(forKey: "hasKeyboardFocus") as? Bool != true {
            focus(field, in: app)
        }
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeDown()
        _ = app.keyboards.firstMatch.disappears(timeout: 3)
    }

    /// The date `daysAgo` days back as the app writes it, such as "Oct 6".
    private static func shortDate(daysAgo: Int) -> String {
        Date.now.addingTimeInterval(-Double(daysAgo) * 86_400).formatted(.dateTime.month(.abbreviated).day())
    }
}

private extension XCUIElement {
    /// Replaces the field's text: deletes what is there, then types `text`.
    func clearAndType(_ text: String) {
        tap()
        let current = value as? String ?? ""
        let placeholder = placeholderValue ?? ""
        if !current.isEmpty, current != placeholder {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
