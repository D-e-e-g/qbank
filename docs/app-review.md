# App Review

What App Review needs to see QBank work, and the notes to paste. Read [release.md](release.md) first for where review fits.

## When review happens

| Route | Review | When |
|---|---|---|
| TestFlight, internal testers (the owner, Khine) | **none**: a build is installable minutes after Apple finishes processing it | phase 2 |
| TestFlight, external testers | Beta App Review of the first build of each version | not planned |
| App Store | full App Review of each version | phase 4, optional |

So nothing in this file is needed for phase 2. It is ready for the day the owner decides to submit to the App Store.

### Before submitting: who can use the app

Today a QBank account exists only for an email the owner put on his sign-up list: he makes it, or its user signs up with that email in the app or on the web (pick 18 of the plan keeps the server for him and Khine). A reviewer can sign in with the demo account below, but a stranger who downloads the app can do nothing past the sign-in screen. Apple may reject such an app, or ask for it to be distributed as an [unlisted app](https://developer.apple.com/support/unlisted-app-distribution/) instead. The plan's answer is phase 4, "free on this phone": the first screen offers using QBank on the phone without an account, so the public listing makes sense. **Submit only after that mode ships**, or request unlisted distribution if a public listing is not wanted.

## How sign-in works

The reviewer needs to understand this, so the review notes below say it in short.

1. The app opens on **Sign in**: email and password fields, a **Sign in** button, and **Sign up**. Sign up makes a user account, signed in at once, only for an email the owner added to the sign-up list on the QBank web app's admin screen. Any other email, or one that already has an account, gets the same refusal, and 5 refused tries lock that email's sign-up for 15 minutes.
2. The app sends the email and password over HTTPS to the QBank server, `https://qbank.dimitrygallego.com`, which answers with a session token. The app keeps the token in the iOS Keychain and sends it with every request. The password is never stored on the phone.
3. After 5 wrong passwords the server locks that email for a short time and says how long; the app shows that message.
4. **Forgot password?** explains that the app sends no email: the owner sets a temporary password from his admin account, and the user chooses a new one at the next sign-in (the **Choose a new password** screen).
5. Signed in, the app opens on Home (courses by semester) and stays signed in for months unless the user signs out, or uses **Sign out everywhere** to end every device's sign-in, in Settings.
6. **Settings > Delete account** deletes the signed-in user account and everything in it for good, after its current password: its courses and study topics, sets, answers, progress and past exams, on every device, with no Undo. The app then signs out and forgets what it kept on the phone. The admin account has no Delete account.

Login rules this meets:

- **Guideline 4.8 (Sign in with Apple)** does not apply: QBank uses only its own account system, no third-party or social login. 
- **Guideline 5.1.1(v), account deletion:** required for apps that let people create an account, and QBank's app does: **Sign up**, for an email on the owner's list. **Settings > Delete account** deletes the account from inside the app (step 6 above), through the server's `DELETE /api/me`.
- **Guideline 2.1, demo account:** required because the app has a login; see below. The server must be up during review.

## Demo account

The owner creates one account only for App Review and types its details into App Store Connect (App Review Information > Sign-in required). The credentials never go into this repository, an issue, a pull request, or a workflow.

| Field | Value |
|---|---|
| Username | DEMO_ACCOUNT_EMAIL (filled in by the owner in App Store Connect only) |
| Password | DEMO_ACCOUNT_PASSWORD (filled in by the owner in App Store Connect only) |

How to make it (owner, on the web app, about five minutes):

1. Pick an email address you control that is not Khine's or yours, for example a `+review` alias of your own address.
2. On the web app's admin screen, add that email to the sign-up list.
3. Sign out, choose **Sign up** in the app or on the web, and create the account with a strong password that is not used anywhere else.
4. Sign in to the iPhone app with it once, answer a few questions in one course, and finish one short exam, so the reviewer sees a Review list and progress instead of empty screens.
5. Keep the account after review: Apple may re-check it with each new version. Change its password after any version is approved if you like, and update App Store Connect at the same time. A reviewer may try **Delete account** on it; if it is gone, make it again the same way before the next submission.

The demo account is an ordinary user account. It has its own sample courses and sets, and it sees only its own questions and answers. Nothing it does touches Khine's questions or progress.

Before every submission, a worker signs in to the TestFlight build of that version with the demo account (the owner gives the credentials to the session, not to a file) and checks that sign-in, one practice set, Review, and an exam work against the live server.

## Review notes

Paste into App Store Connect (App Review Information > Notes). Fill the marked words first: the review contact.

```text
QBank is an NCLEX-style practice question bank for nursing students. It is the iPhone client of a private QBank server (https://qbank.dimitrygallego.com) that also serves a web app.

Sign in: Sign up makes an account only for an email the server's owner has added, so it refuses any other email. Please use the demo account in the Sign-In Information fields. It is a normal user account with a few answers already given, so Review and progress are not empty.

What to try:
1. Sign in. Home lists courses by semester.
2. Open a course, open one of its pages and one of its folders, open a practice set, and answer a few questions. Tap "Check answer" to see per-choice reasons, the rationale and the key takeaway. Mark one answer "I'm guessing".
3. Finish or leave the set, then open Review from the course to see missed, partly right and guessed questions.
4. Open Exam in the course, pick folders (or "Wrong questions only"), and start a timed exam. "End exam" scores what was answered.
5. Turn on Airplane Mode and answer a practice question: it is saved on the phone and sent when the connection returns. Exams need a connection.

Accounts: Sign up makes an account only for an email the owner has added. To delete an account in the app, open the Settings tab, tap Delete account, enter the account's password, and tap Delete account: the account and everything in it are deleted for good, on every device. There is no third-party or social login (Guideline 4.8 does not apply).

The app has no ads, no tracking, no analytics, and no in-app purchases. It uses only standard HTTPS encryption.

NCLEX is a registered trademark of NCSBN; QBank is not affiliated with NCSBN.

Contact during review: REVIEW_CONTACT_NAME, REVIEW_CONTACT_PHONE
```

Phase 4 adds one paragraph for the "use it on this phone" mode, with a line telling the reviewer they can also try the app without the demo account.

## App Review contact

App Store Connect asks for a first name, last name, phone, and email that Apple can use during review. These are the owner's real details, typed into App Store Connect only. They never go into this repository.

## If App Review rejects

- Read the message in App Store Connect (Resolution Center) and reply there; most first rejections are questions, not refusals.
- "Information needed" about sign-in: check the demo account still works on the live server, then reply with the same notes.
- Limited audience or login-only: see "Before submitting" above.
- Trademark (Guideline 5.2) on "NCLEX": use the fallback subtitle in [app-store-listing.md](app-store-listing.md).
- A worker drafts the reply and any listing change; the owner sends it and resubmits.
