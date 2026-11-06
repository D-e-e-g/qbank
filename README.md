# QBank for iPhone and iPad

QBank is an NCLEX practice question bank: courses, practice sets in folders, a review list of missed questions, and timed exams. This repository is its iPhone and iPad app, written in SwiftUI.

The app is a client of a private QBank server. The server, the web app, and their deployment live in a separate private repository; nothing here runs or configures them.

**Status:** early. The app makes a user account for an email the owner has added (Sign up), signs in by password, which iOS Password AutoFill can fill with Face ID, shows each course, and each study topic you make for questions that are not a course, as its pages and folders, where a page can carry one badge, Exam, Concept or Study, set in its editor, and a topic's page a primer link, and folders you can rename, put in your order, and move sets between, deletes a set, a folder with its sets, a page (its folders stay, with their sets), or a past exam after a warning that says what goes, with Undo and a Recently deleted list that brings things back for 30 days, practices a set in all eight question formats with the rationale after each answer and the set result at the end, opens a set you left midway at the first question you have not answered, on any device, with Start over to begin it again, lets you strike out the choices you rule out while you answer a practice or exam question and restore one with the same tap, has Review, Terms, and timed exams over the folders you pick or only the questions you last got wrong, keeps your courses on the device so you can practice without signal and sends those answers when you are back online, imports a question file into the course or topic and folder you pick from the Add tab, or the + on a course, page or folder, adds a semester, a course or a study topic from the + on Home, renames, moves, archives or deletes a course or topic, or puts a topic in your order, when you touch and hold it on Home, with Delete asking once and Home's own Recently deleted bringing a deleted course or topic back for 30 days, and Settings has your account, password, Connect an agent, where you type or paste the short code your own AI agent shows, see what it asks to do, approve or deny it, and see or revoke your agent keys (a set your agent imported says so in its folder), Sign out everywhere, which ends your sign-in on every device, Delete account, which deletes your user account and everything in it for good, an optional Face ID lock, each semester's name and dates, light or dark Look, and Color, Dusk or Slate, saved to your account. Making questions from your notes, photos, or a PDF is built in the Add tab, and Exam setup can write exam twins of the questions in the folders you tick and start the exam on the twins; both show once the QBank server offers making questions to your account. On iPad your courses stay in a sidebar beside the one you open, and every screen keeps a readable width. TestFlight build 0.1 is out to the internal testers; there is no App Store release.

## Getting started

You need Xcode 26 or later. The app runs on iPhone and iPad with iOS 18 or later.

Open `QBank.xcodeproj` in Xcode and run the `QBank` scheme, or build and test from the command line:

```sh
test/sim.sh -- xcodebuild test \
  -project QBank.xcodeproj -scheme QBank \
  -destination 'platform=iOS Simulator,id={{UDID}}'
```

`test/sim.sh` creates a fresh simulator for the run and deletes it afterwards. It picks an iPhone; pass `--device "iPad Pro 13-inch (M5)"` to run on an iPad, where the iPad layout's UI tests run and the iPhone layout's skip. `test/release-checks.sh` checks the repository rules and needs no Xcode.

## Layout

- `QBank/` - the app
- `QBankTests/` - unit tests (Swift Testing)
- `QBankUITests/` - UI tests (XCTest)
- `Packages/QBankDesign/` - the design system: colors, type, spacing and base SwiftUI components shared with the web app
- `Packages/QBankKit/` - the API client, session store, and offline core, as a Swift package with no UI
- `test/` - simulator wrapper, package tests, and repository checks
- `scripts/` - the TestFlight build-and-upload script, run on the owner's Mac
- `docs/ci.md` - how CI runs
- `docs/release.md` - how a build reaches TestFlight

## Security and support

Report security issues privately as described in [SECURITY.md](SECURITY.md). For build and code questions, see [SUPPORT.md](SUPPORT.md).

## License

No license for now.
