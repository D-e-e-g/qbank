# App Store listing

The text and choices for QBank's App Store Connect record, ready to paste. Nothing here is live: TestFlight (phase 2) needs only the app record, and this listing matters when the app is submitted for the App Store (phase 4 of the plan). [release.md](release.md) says who does each step.

The copy describes only what the build does. Apple rejects a listing that promises features the build lacks (App Review Guideline 2.3), so the "phase 4" lines below are added only when that phase ships.

## Identity

| Field | Value | Limit |
|---|---|---|
| Name | **My QBank**, as the app record was created on 2026-10-16 (App Store names are unique worldwide). The name under the icon on the home screen stays **QBank**, from the app's `CFBundleDisplayName`. The App Store name can still change before the first submission. | 30 characters |
| Subtitle | **NCLEX practice and exams** | 30 |
| Fallback subtitle | **Nursing practice questions**, if App Review objects to "NCLEX" (see trademark note) | 30 |
| Bundle ID | `com.dimitrygallego.qbank` (set in the Xcode project) | |
| SKU | `qbank-ios` (private, never shown) | |
| Primary language | English (U.S.) | |
| Primary category | **Education** | |
| Secondary category | none. Medical is not recommended: Apple reviews Medical apps more strictly (Guideline 1.4.1) and QBank gives no medical advice. | |
| Price | Free | |
| In-app purchases | none | |
| Copyright | `2026 OWNER_NAME` (the name on the Apple Developer account) | |

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL (required) | https://github.com/D-e-e-g/qbank/blob/main/docs/privacy-policy.md, once its contact line is filled in. A GitHub Pages copy like Kun's can replace it later; the link stays valid either way. |
| Support URL (required) | https://github.com/D-e-e-g/qbank/issues |
| Marketing URL (optional) | none |

## Promotional text

Up to 170 characters; can change at any time without a new review.

> Practice NCLEX-style questions on your iPhone or iPad: all eight question formats, rationales for every answer, a Review list of what you missed, and timed exams.

## Description

Up to 4,000 characters. Paste as is.

```text
QBank is a question bank for nursing students preparing for course exams and the NCLEX. Sign in with your QBank account and pick up where you left off on the web: the same courses, the same questions, and the same progress.

Practice the way the exam asks
- Eight NCLEX-style question formats: single answer, select all that apply, priority and first action, highlight, ordering, matching, matrix, and drop-down.
- Tables and images inside the question, like a real chart.
- Mark an answer as a guess, so a lucky guess still comes back for review.
- After each answer: what was right, what each choice means, the rationale, a key takeaway, and the terms used in the question.
- Results by clinical judgment step, so you see whether you miss cues, analysis, or actions.

Review what you missed
- Missed, partly right, and guessed questions collect in Review, per course.
- Practice your Review list shuffled, and clear a question once you know it.
- Look up every term in a course in one searchable list.

Timed exams
- Build an exam from the folders you choose, at 1.5 minutes per question.
- Or make it only from the questions you last got wrong.
- See your score by folder and by clinical judgment step when you finish.

Study without signal
- Your courses stay on your iPhone or iPad. Practice offline, and your answers send by themselves when you are back online.

Private by design
- No ads, no tracking, no third-party analytics.
- Lock QBank with Face ID, Touch ID or your passcode.
- Export your answers and progress as a file whenever you like.

QBank works with an account on a QBank server. Sign up in the app with an email the server's owner has added, or sign in with the account he made for you.

NCLEX and NCLEX-RN are registered trademarks of the National Council of State Boards of Nursing, Inc. QBank is not affiliated with or endorsed by NCSBN.
```

Phase 4 replaces the last two paragraphs before the trademark line with a paragraph about using QBank free on the phone without an account, once that mode exists.

## Keywords

Up to 100 characters, comma-separated, no spaces after commas. Words already in the name or subtitle ("qbank", "nclex", "practice", "exams") count automatically and are left out.

```text
nursing,RN,NGN,question bank,quiz,review,rationale,clinical judgment,SATA,nurse,student,test prep
```

97 characters. "NCLEX" stays out of the keywords on purpose: Guideline 2.3.7 warns against packing metadata with trademarked terms, while the subtitle and description use it only to describe what the app prepares for.

### Trademark note

"NCLEX" is a registered trademark of NCSBN. Describing an app as practice for the NCLEX is common on the App Store and the description carries the disclaimer above. If App Review still raises Guideline 5.2 (intellectual property), switch to the fallback subtitle and drop "NCLEX" from the promotional text; the description's disclaimer line stays.

## Age rating

App Store Connect asks a questionnaire; these are the answers for QBank's content, which is nursing course material.

| Question | Answer | Why |
|---|---|---|
| Parental controls | not present | |
| Age assurance | not present | |
| Unrestricted web access | not present | the app opens no web pages |
| User-generated content | not present | answers are private to each user; nothing is shared between users |
| Social media | not present | |
| Messaging and chat | not present | |
| Advertising | not present | |
| Profanity or crude humor | none | |
| Horror or fear themes | none | |
| Alcohol, tobacco, or drug use | infrequent | clinical questions mention medications, withdrawal, and substance use as nursing care topics |
| Medical or treatment information | **frequent** | every question is about nursing care, medications, and treatment |
| Health or wellness topics | present | mental health and wellness are course topics |
| Mature or suggestive themes | infrequent | questions about suicide risk, abuse, and restraint as clinical situations |
| Sexual content or nudity | none | |
| Graphic sexual content and nudity | none | |
| Cartoon or fantasy violence | none | |
| Realistic violence | infrequent | clinical scenarios with aggressive clients |
| Prolonged graphic or sadistic realistic violence | none | |
| Guns or other weapons | none | |
| Contests, loot boxes, simulated gambling, gambling | none | |

Expected result: **16+**, set by "frequent medical or treatment information". That is right for a nursing licensing-exam app and harmless for its users, who are adults. Revisit the answers when a new kind of content arrives (phase Q question-writing, phase 3 import), since users' own sets could cover other topics.

## Screenshots

App Store Connect needs one iPhone set at **6.9 inch, 1320 x 2868 pixels portrait** (Apple scales it down for smaller iPhones); 3 to 10 images. The app runs on iPad too, so App Store Connect also needs one iPad set at **13 inch, 2064 x 2752 pixels portrait**; 3 to 10 images, taken the same way on a 13-inch iPad simulator or device.

Take them from a TestFlight build signed in to a **demo account**, never a real user's account, so no real progress shows. The question text shown comes from the demo account's own sample courses and sets.

The list follows the approved phase-W wireframes (`qbank-ios-wireframes`, approved 2026-10-12), in this order:

| # | Wireframe frame | What it shows | Caption |
|---|---|---|---|
| 1 | 1b-2 Priority / first action, with a table | a question with a vitals table | Questions like the real exam |
| 2 | 1b-4 Answer feedback | per-choice reasons, rationale, takeaway, terms | Learn from every answer |
| 3 | 1a-3 Home | semesters, courses, review counts, progress | All your courses in one place |
| 4 | 1b-10 Set result | score by clinical judgment step | See which step you miss |
| 5 | 1c-1 Review | missed, partly right, guessed, "Practice these" | Review what you missed |
| 6 | 1c-3 Exam setup, wrong questions only | folder picker with wrong counts | Exams from your weak spots |
| 7 | 1c-4 Exam in progress | timer, Skip for now, Submit and continue | Timed like test day |
| 8 | 1b-8 Matrix | a matrix question | All eight question formats |
| 9 | 1e-1 Home, no connection | offline banner, answers waiting to send | Study without signal |

Left out on purpose: sign-in and password screens (Guideline 2.3.3: screenshots show the app in use, not its login page), Settings, and the phase 3, Q, and 4 frames until those ship. Phase 4 adds the first-run frame (4-1, "Use it on this phone") as screenshot 3 when that mode exists.

Captions are optional overlay text; plain device screenshots without captions are also fine. Apple allows an app preview video; none is planned.

## What's New

Each App Store version needs release notes. The first one:

```text
The first release of QBank for iPhone and iPad.
```

Later versions: one or two plain sentences on what changed for users, written from the release PR.
