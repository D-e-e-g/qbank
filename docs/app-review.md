# App Review

What App Review needs to see QBank work in the store release, and the notes to paste. [app-store-setup.md](app-store-setup.md) is the owner's checklist on Apple's side; [app-store-listing.md](app-store-listing.md) holds the listing. Every statement here was checked against the app's code on `main`; [cloud.md](cloud.md) is the design record behind the account and QBank Cloud parts.

## When review happens

| Route | Review |
|---|---|
| TestFlight, internal testers | **none**: a build is installable minutes after Apple finishes processing it ([release.md](release.md)) |
| TestFlight, external testers | Beta App Review of the first build of each version; not planned |
| App Store | full App Review of each version. The first version is reviewed together with the two QBank Cloud subscriptions ([app-store-setup.md](app-store-setup.md) step 18). |

## No demo account

The reviewer signs in with **their own Apple Account**, through Sign in with Apple on the first screen. That makes an ordinary new user account, the same as any stranger who downloads the app gets, with the sample set ready to practice. So **Sign-in required** stays off in App Store Connect and no credentials are entered ([app-store-setup.md](app-store-setup.md) step 15).

Only if App Review asks for an account for the email-and-password door, the owner makes one with [the steps below](#if-apple-asks-for-an-email-and-password-account).

## Before submitting

Each step is done for the exact build that is submitted, on the live server.

1. **Apple's side is set up.** [app-store-setup.md](app-store-setup.md) steps 1 to 16: the Paid Apps agreement is active, both subscriptions exist with their review screenshot (`docs/app-store-screenshots/review/cloud-plans.png`), App Store Server Notifications point at the live server (step 10), and App Privacy, the age rating, content rights, availability, price and the review contact are entered.
2. **A device pass on that build from TestFlight**, on a real iPhone and a real iPad:
   - Sign in with Apple with the real Apple sheet; Home shows "Getting started".
   - Buy each plan with a sandbox Apple Account. The server confirms it (its log shows the purchase and the notification), the bank moves to QBank Cloud, and Settings says QBank Cloud is on.
   - Sign in with the same Apple Account on the second device after it already holds a bank of its own: the combine runs on its own and ends on "Your banks are combined", and nothing is missing from either device.
   - Settings > Delete account on a Sign in with Apple account: Apple's sheet confirms, the account is gone from the server, and the app is back at the first screen.
   - Write the devices and iOS versions into the notes' "Devices tested" line.
3. **The server is ready for review.** It is up, `GET /api/me/cloud` answers `combinePaused` false, and no server change is deployed while the version is in review.
4. **The pages answer.** https://qbank-app.dimitrygallego.com/privacy, `/support` and `/format` each load over HTTPS.
5. **The notes are filled in.** Paste [the review notes](#review-notes) with the device line and the contact filled in, in App Store Connect only.

## How sign-in works

1. **The first screen** shows **Sign in with Apple**, and below it **Use an existing QBank account**, with **Privacy policy** and **Terms of use** at the bottom. There is no Sign up in the app (`QBank/SignIn/WelcomeView.swift`).
2. **Sign in with Apple** sends Apple's identity token and a nonce to the QBank server, which checks it against Apple's keys and opens or makes the user account. A new account's bank is on the device, with the sample set "General knowledge sampler" in the study topic "Getting started". If the server cannot be reached right then, the bank on the device opens anyway, and the app sends the sign-in again later; Settings says it is waiting.
3. **The email door.** "Use an existing QBank account" opens email and password fields and a **Sign in** button. It is only for the user accounts the owner set up before the store release, which keep their bank on the server and also use the web app. It makes no account: an email that is not already a QBank account is refused. **Forgot password?** says the app sends no email and that the owner sets a temporary password. An Apple email that already belongs to one of those accounts is refused at Sign in with Apple, with a sentence that opens the email door; the two are never joined by matching email. Such an account can link Sign in with Apple itself, from Settings.
4. **Deleting the user account is in Settings**, for every kind of account: **Settings > Delete account**.
   - An account made with **Sign in with Apple**, free or with QBank Cloud, confirms with a fresh Sign in with Apple. The app checks the session with the server first, erases what it kept on the device, then the server uses Apple's authorization code to revoke the app's Apple tokens and deletes the account and everything in it. The screen says that deleting does not cancel a QBank Cloud subscription and offers **Manage subscription** (`QBank/Settings/AppleDeleteAccountView.swift`).
   - An **email-and-password** account confirms with its password, through the same server route.
   - The owner's admin account has no Delete account.

Rules this meets:

- **Guideline 4.8, Sign in with Apple**: it is the first choice on the first screen. The only other way in is QBank's own email and password, for accounts made before this release.
- **Guideline 5.1.1(v), account deletion**: Sign in with Apple makes an account, and Settings > Delete account deletes it in the app, revoking the Apple tokens for an account made with Apple.
- **Guideline 2.1, a way in for review**: the reviewer's own Apple Account is enough. The server must be up during review.
- **Guideline 3.1.2, subscriptions**: the plans sheet shows each plan's name, period and price from StoreKit, the renewal terms, the privacy policy and the terms of use, and Restore purchases; the description carries the terms and both links.

## What is off for accounts made with Sign in with Apple

Free or with QBank Cloud, these are hidden in the app and refused by the server. They exist in the same build only for the user accounts the owner set up.

| Off | Why |
|---|---|
| Make questions and exam twins | They send the person's material to Anthropic's Claude API from the server, at the owner's cost, and the owner turns them on per account. |
| Connect an agent (agent keys) | Kept to the owner's accounts in this release. |
| Change password | An account made with Apple has no password. |
| The web app | It signs in with email and password only in this release. |
| Saved for offline, while the bank is on the device | The whole bank is already on the device. An account with QBank Cloud has it. |

The review notes say this in short, so the reviewer does not look for features that are not part of what is sold (Guideline 2.3.1).

## Outside services

| Service | What for | Who reaches it |
|---|---|---|
| Apple | Sign in with Apple, the App Store purchase, and revoking Apple's tokens when an account is deleted | the app, and the server for the revoke |
| QBank's server, `https://qbank.dimitrygallego.com` | the user account and its sessions; with QBank Cloud, the bank itself; deciding who has QBank Cloud from Apple's signed transactions and notifications | the app, over HTTPS |
| GitHub Pages, `https://qbank-app.dimitrygallego.com` | the privacy policy, help and question file format pages, opened in Safari's view | the person, when they tap a link |
| Anthropic's Claude API | Make questions and exam twins | the server only, and only for the owner's accounts; never the app, and never an account made with Apple |

No analytics, crash reporting, advertising or tracking service, and no third-party code in the app. Encryption is standard HTTPS only (`ITSAppUsesNonExemptEncryption` is `NO`).

## Devices tested

The UI tests run the app on iPhone and iPad simulators through the Debug launch seam, with a fake server and a scripted Apple sheet and store ([testing.md](testing.md)); the App Store screenshots come from a 6.9-inch iPhone and a 13-inch iPad Pro simulator. The real Apple sheet, a sandbox purchase and the combine on two devices are proven only by the device pass in [Before submitting](#before-submitting), which names the devices for the notes.

## Review notes

Paste into App Store Connect (App Review Information > Notes), at most 4,000 bytes. Fill the marked words first: `DEVICES_TESTED` from the device pass, and the review contact.

```text
QBank is a study app: people practice their own questions on any course or topic, review what they missed and take timed exams. The bank is stored on the device and works offline. QBank Cloud, an optional auto-renewable subscription, keeps the bank on QBank's own server instead, so it is on every iPhone and iPad where the person signs in.

SIGN IN - NO DEMO ACCOUNT NEEDED
Tap Sign in with Apple on the first screen and use your own Apple Account. A new account opens with a short sample set in the study topic "Getting started".
"Use an existing QBank account" (email and password) is only for a few accounts the developer set up before this release. No account can be made there; the app has no sign-up by email.

WHAT TO TRY
1. Home > Getting started: open the set and answer a few questions. Tap "Check answer" to see the rationale. Turn on "I'm guessing" for one.
2. In the topic, open Review: missed and guessed questions collect there.
3. In the topic, open Exam, pick the folder, tap "Start exam", then "Finish exam".
4. Add tab: "Write questions" makes a set by hand. "Import a question file" takes a JSON file in the format at https://qbank-app.dimitrygallego.com/format
5. Turn on Airplane Mode: practice, Review and exams keep working, since the bank is on the device.

QBANK CLOUD (SANDBOX PURCHASE)
Settings > QBank Cloud opens the plans: Monthly and Yearly, each with its price and period, the renewal terms, Privacy policy, Terms of use (Apple's standard EULA) and Restore purchases. Buy either one with a sandbox account. Once QBank's server confirms the purchase, the app moves the bank to QBank Cloud and shows what moved.
Signing in with the same Apple Account on a second iPhone or iPad opens the bank in QBank Cloud. If that device already holds a bank of its own, or a subscriber comes back after Cloud ended, the app combines the two banks on its own, then says what was combined ("Your banks are combined"). Nothing is removed from either side. If the subscription ends, the bank comes back to the device.

DELETE ACCOUNT
Settings > Delete account, for every account. An account made with Sign in with Apple confirms with Sign in with Apple; the server revokes the app's Apple tokens, then deletes the account and everything in it. The screen says deleting does not cancel a subscription and offers Manage subscription. An email-and-password account confirms with its password.

NOT SHOWN TO NEW ACCOUNTS
Make questions and exam twins (AI writing through Anthropic, paid by the developer and turned on per account), Connect an agent, Change password and the web app exist only for the accounts the developer set up. They are hidden from accounts made with Sign in with Apple on purpose and are not part of what is sold.

OTHER SERVICES
Apple (Sign in with Apple, in-app purchase) and QBank's own server, over HTTPS. The privacy policy and help pages open in Safari's view. No ads, analytics, tracking or third-party SDKs.

Devices tested: DEVICES_TESTED

Contact during review: REVIEW_CONTACT_NAME, REVIEW_CONTACT_PHONE
```

## App Review contact

App Store Connect asks for a first name, last name, phone and email that Apple can use during review. These are the owner's real details, typed into App Store Connect only. They never go into this repository.

## If Apple asks for an email-and-password account

Only if App Review says it needs to see the email door. The account is an ordinary user account, and nothing it does touches any other account.

1. Pick an email address the owner controls that no account uses yet, for example a `+review` alias of the owner's own address.
2. On the web app's admin screen, add that email to the sign-up list.
3. On the web app, sign up with that email and a strong password used nowhere else. The iPhone app has no Sign up.
4. Sign in to the iPhone app with it through "Use an existing QBank account", answer a few questions and finish one short exam, so Review and progress are not empty.
5. Type the email and password into App Store Connect (App Review Information > Sign-in required) and nowhere else: never into this repository, an issue, a pull request or a workflow. Reply in the Resolution Center that the account is there.
6. A reviewer may delete it. Make it again the same way before the next submission that needs it.

## If App Review rejects

- Read the message in App Store Connect (Resolution Center) and reply there; most first rejections are questions, not refusals.
- **Sign-in or the email door (2.1)**: check that the server is up and Sign in with Apple works on the submitted build, then reply with the notes' sign-in paragraph. If Apple still asks for an account, see the section above.
- **Login required (5.1.1)**: the account is what QBank Cloud, the subscription and Delete account hang on, and it asks for nothing but Sign in with Apple. Reply with that.
- **Subscription metadata (3.1.2)**: check the description still ends with the terms and privacy links, and point to the plans sheet's review screenshot.
- **Hidden or unreachable features (2.3.1)**: point to "Not shown to new accounts" in the notes.
- A worker drafts the reply and any listing change; the owner sends it and resubmits.
