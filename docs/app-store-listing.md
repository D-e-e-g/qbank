# App Store listing

The text and choices for QBank's App Store record, ready to paste, for the store release: a general study tool, free and complete on the device, with QBank Cloud as an optional subscription. [app-store-setup.md](app-store-setup.md) says where each field is in App Store Connect and in what order the owner enters them; [app-review.md](app-review.md) holds the review notes.

The copy describes only what the build does. Apple rejects a listing that promises features the build lacks (App Review Guideline 2.3), so a line is added here only when its feature ships, and a line goes when its feature changes. The words below were checked against the app's code on `main`; where a sentence repeats what a screen says, it uses the screen's words.

## Identity

| Field | Value | Limit |
|---|---|---|
| Name | **My QBank**, as the app record was created on 2026-10-16 (App Store names are unique worldwide). The name under the icon on the home screen stays **QBank**, from the app's `CFBundleDisplayName`. | 30 characters |
| Subtitle | **Practice questions, any topic** (29) | 30 |
| Bundle ID | `com.dimitrygallego.qbank` (set in the Xcode project) | |
| SKU | `qbank-ios` (private, never shown) | |
| Primary language | English (U.S.) | |
| Primary category | **Education** | |
| Secondary category | none | |
| Price | Free | |
| In-app purchases | Two auto-renewable subscriptions in the group **QBank Cloud**: `com.dimitrygallego.qbank.cloud.monthly` (1 month, US$4.99) and `com.dimitrygallego.qbank.cloud.yearly` (1 year, US$29.99). No free trial, Family Sharing off. Names, descriptions and the review screenshot are in [app-store-setup.md](app-store-setup.md) step 8. | |
| Copyright | `2026 OWNER_NAME` (the name on the Apple Developer account, typed in App Store Connect only) | |

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL (required) | https://qbank-app.dimitrygallego.com/privacy, served from `site/` by GitHub Pages ([ci.md](ci.md#public-pages-pagesyml)) |
| Support URL (required) | https://qbank-app.dimitrygallego.com/support |
| Marketing URL (optional) | none |
| Terms of use (in the description) | Apple's standard licensed application end user license agreement, https://www.apple.com/legal/internet-services/itunes/dev/stdeula/. The app links the same address on the first screen, in Settings and on the plans sheet (`QBank/Shared/LegalLinks.swift`). No custom EULA is entered in App Store Connect. |

## Promotional text

Up to 170 characters; can change at any time without a new review.

> Practice your own questions on any course or topic, even offline: nine question formats, a Review list of what you missed, and timed exams. Free on iPhone and iPad.

## Description

Up to 4,000 characters. Paste as is. Guideline 3.1.2 wants the subscription's terms, a link to the terms of use and a link to the privacy policy in the metadata of an app that sells a subscription; the last section carries all three.

```text
QBank is a question bank for anything you study: a course, an entrance or licensing exam, a language, or your own notes. Bring your questions, practice them the way the exam asks, and see what to review next.

Start in seconds
- Sign in with Apple. A short sample set is ready to practice at once.
- Your whole bank is on your iPhone or iPad and works without a connection: practice, Review and timed exams.

Bring your own questions
- Import a question file. The format is published on QBank's website.
- Or write questions in the app: single answer, select all that apply, and true or false.
- Keep them in study topics or courses, with pages and folders.

Practice the way the exam asks
- Nine question formats: single answer, priority and first action, select all that apply, highlight, ordered response, matching, matrix, matrix with several answers per row, and drop-down.
- Tables and images inside the question.
- Mark an answer as a guess, so a lucky guess still comes back for review.
- After each answer: what was right, and the rationale and key takeaway when your set has them.

Review what you missed
- Missed, partly right and guessed questions collect in Review. Practice them shuffled; a question leaves once you answer it fully right without guessing.
- Look up every term your sets define in one searchable list.

Timed exams
- Build an exam from the folders you choose: up to 40 questions in 60 minutes, or 1.5 minutes a question when there are fewer.
- Or make it only from the questions you last got wrong.
- See your score by folder when you finish.

Private by design
- No ads, no tracking, no analytics.
- Lock QBank with Face ID, Touch ID or your passcode.
- Export your whole bank, questions and progress, as one file whenever you like.
- Delete your account and everything in it from Settings.

QBank Cloud, an optional subscription
QBank is free and complete on one device. QBank Cloud keeps your bank on the QBank service instead, so the same sets and progress are on every iPhone and iPad where you sign in with your Apple Account. If QBank Cloud already holds a bank for you, from another device or an earlier subscription, QBank combines it with the bank on your device and then shows what was combined. Nothing is removed. With QBank Cloud, practice works without a connection; exams and adding sets need one. If your subscription ends, your bank comes back to your device.

- QBank Cloud Monthly renews every month, and QBank Cloud Yearly every year. The price in your country is shown in the app before you buy.
- Payment is charged to your Apple Account when you confirm the purchase. The subscription renews automatically for the same period and price unless you cancel it at least 24 hours before the current period ends. Manage or cancel it at any time in your Apple Account's subscription settings.
- Deleting your QBank account does not cancel a subscription.

Terms of use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy policy: https://qbank-app.dimitrygallego.com/privacy
```

About 3,000 characters. What each claim rests on:

| Claim | Where the build does it |
|---|---|
| Sign in with Apple; a sample set at once | `QBank/SignIn/WelcomeView.swift`; `QBank/FirstRun/SampleSet.swift` files "General knowledge sampler" into the topic "Getting started" for a new account whose bank is on the device |
| The bank on the device, offline, exams included | the on-phone bank (`Packages/QBankKit/Sources/QBankKit/LocalBank/`), whose exams use `ExamPlanner.swift` |
| Import a file; the published format | Add > Import a question file; https://qbank-app.dimitrygallego.com/format |
| Write questions: three formats | Add > Write questions (`QBank/Add/WriteDraft.swift`: single answer, select all, true or false) |
| Nine formats | `Packages/QBankKit/Sources/QBankKit/Models/Question.swift`, named as `/format` names them |
| Guess, rationale, takeaway | `QBank/Practice/` ("I'm guessing", "Check answer"); a rationale or takeaway shows only when the question has one |
| Review leaves on a fully right answer without a guess | `QBank/Review/ReviewView.swift` |
| Terms | the topic's Terms list (`QBank/Terms/TermsView.swift`) |
| Exam size and time | `ExamPlanner.rules`: 40 questions, 60 minutes, 90 seconds a question; "Wrong questions only" on Exam setup; the result by folder |
| Lock, Export, Delete account | `QBank/Lock/`; Settings > Export my bank; Settings > Delete account |
| QBank Cloud text | the plans sheet's own words (`QBank/Cloud/CloudWording.swift`), the combine's (`CloudCombineWording.swift`), the hand-back's (`CloudReturnWording.swift`) and the delete screen's (`QBank/Settings/AccountDeletionWording.swift`) |

Left out on purpose:

- **Make questions, exam twins and Connect an agent.** The app hides them from every account made with Sign in with Apple ([cloud.md](cloud.md#what-is-off-for-store-accounts)), so the listing does not offer them.
- **The web app.** An account made with Sign in with Apple cannot use it in this release.
- **"By clinical judgment step" on results.** It shows only for sets whose questions carry that label, so it is not a promise to make to everyone.
- **Prices in the description.** Apple sets each storefront's price from US$4.99 and US$29.99; the app shows the local price from StoreKit before the purchase.
- **Any exam's brand name.** QBank is not tied to one exam, and a trademark in the metadata invites Guideline 2.3.7 and 5.2 questions.

## Keywords

Up to 100 characters, comma-separated, no spaces after commas. Words already in the name or subtitle ("my", "qbank", "practice", "questions", "any", "topic") count automatically and are left out.

```text
study,quiz,exam prep,test prep,question bank,review,timed exam,offline,rationale,course,learn
```

93 characters. Every word describes what the app does; no competitor or trademark is named (Guideline 2.3.7).

## Age rating

App Store Connect asks a questionnaire ([app-store-setup.md](app-store-setup.md) step 13). The answers describe what the build ships and what it lets people do. The only content it ships is the sample set: ten general-knowledge questions on science, math, geography, language, history and study habits. Everything else is what each person imports or writes for themselves. It stays in their own bank, private to their user account, and nothing is shared with another user, so it is not user-generated content in Apple's sense.

| Question | Answer | Why |
|---|---|---|
| Parental controls | not present | |
| Age assurance | not present | |
| Unrestricted web access | not present | the app opens only its fixed privacy, help and terms pages, in Safari's view, with no address bar |
| User-generated content | not present | a person's sets, answers and progress are private to their user account; there is no sharing, profile or feed |
| Social media | not present | |
| Messaging and chat | not present | |
| Shared location | not present | |
| Advertising | not present | |
| Profanity or crude humor | none | |
| Horror or fear themes | none | |
| Alcohol, tobacco, or drug use or references | none | |
| Mature or suggestive themes | none | |
| Medical or treatment information | none | the app gives no medical advice and ships no medical content |
| Health or wellness topics | none | |
| Sexual content or nudity | none | |
| Graphic sexual content and nudity | none | |
| Cartoon or fantasy violence | none | |
| Realistic violence | none | |
| Prolonged graphic or sadistic realistic violence | none | |
| Guns or other weapons | none | |
| Contests | none | |
| Loot boxes, simulated gambling, gambling | none | |

Then **Age Categories and Override**: **Not Applicable**, and the Age Suitability URL left empty. Never pick **Made for Kids**.

Expected result: **4+**. The nursing-era answers (16+, from frequent medical content) described a bank the store build no longer ships and are replaced, not reused. Revisit these answers when the app starts to ship content of its own beyond the sample set, or adds any way to share a set with another person.

## Content rights

On **App Information** > **Content Rights**: **No**, the app does not contain, show or access third-party content. The sample set was written for QBank. Every other question in a person's bank is one they imported or wrote themselves, kept for them alone and never shown to anyone else.

## Trader status and availability

- **Digital Services Act: not a trader.** The owner chose not to be a trader in the EU ([app-store-setup.md](app-store-setup.md) step 5), so no trader contact details are entered or shown.
- **Countries and regions: every storefront but mainland China and the 27 EU member states**, 147 by Apple's availability page (the screen may show 146; [app-store-setup.md](app-store-setup.md) step 14 lists the 28 to clear and says why the count can differ). Mainland China is out because it needs an ICP filing number; the EU is out because selling there needs trader status. Either can be added later. The two subscriptions are sold in the same storefronts.

## Screenshots

App Store Connect needs one iPhone set at **6.9 inch, 1320 x 2868 pixels portrait** (Apple scales it down for smaller iPhones) and, since the app runs on iPad, one iPad set at **13 inch, 2064 x 2752 pixels portrait**; 3 to 10 images each.

The committed sets are in [app-store-screenshots/](app-store-screenshots/README.md), taken by `StoreScreenshotsUITests` from a free account's first launch with the sample set. App Store Connect shows each set in file name order; upload them in that order, as plain device pictures with no captions:

| # | File | Shows | iPhone | iPad |
|---|---|---|---|---|
| 1 | `01-question` | a question with a diagram, a choice picked | yes | yes |
| 2 | `02-answer` | a checked answer with its rationale and key takeaway | yes | yes |
| 3 | `03-home` | Home with the sample set's topic; on iPad the topic is open beside the list | yes | yes |
| 4 | `04-topic` | the topic, with Exam, Review, Terms and its page | yes | no |
| 5 | `05-result` | the result of the set | yes | yes |
| 6 | `06-review` | Review: what was missed, partly right or guessed | yes | yes |
| 7 | `07-exam` | a timed exam in progress | yes | yes |

So the iPhone set has 7 pictures and the iPad set 6. `review/cloud-plans.png` is not a store picture: it is the review screenshot of each QBank Cloud subscription.

With the sample set alone the iPhone Home picture (`03-home`) is mostly empty. The owner decides before submission whether to keep it, drop it, or retake the set with more on Home ([app-store-screenshots/README.md](app-store-screenshots/README.md) says how to retake).

Left out on purpose: the first screen (Guideline 2.3.3: screenshots show the app in use, not its sign-in), Settings, and the features a Sign in with Apple account does not have. No app preview video is planned.

## What's New

Each App Store version needs release notes. The first one:

```text
The first App Store release of QBank: practice questions on any course or topic, on your iPhone or iPad, with QBank Cloud to keep your bank on all your devices.
```

Later versions: one or two plain sentences on what changed for people using the app, written from the release pull request.
