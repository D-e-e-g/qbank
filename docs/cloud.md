# Accounts and Cloud

The design record for who is signed in, where their question bank lives, and how a whole bank moves between the phone and the server. [on-phone-bank.md](on-phone-bank.md) is its other half: the bank on the phone and the bank archive format.

This is a record to build to, not a description of shipped code. Only Getting in exists so far (I-30), and its section says what was built. Statements about today's code name the file and line; they were read at app commit `45ec726` and server commit `b913bcc` (`D-e-e-g/qbank-server`, whose paths start with `apps/` or `packages/`).

Ids such as A3, I-34 and S-03 name calls and pull requests in the App Store release plan, and OD1 and OD2 name owner questions. The maintainers keep that plan outside this repository, and a worker's brief says where.

## The model in one paragraph

QBank on the App Store is a general study tool. The whole question bank is free and complete on the phone. Everyone signs in with Apple at first launch, and the server verifies it. Keeping the bank on the server instead, so it follows the person to every device, is Cloud: an optional paid subscription, with the server as the authority on who has it. The accounts the owner set up before the store release keep working as they do today, in the app and on the web.

## Three kinds of account

| | Free | Cloud | Invited |
|---|---|---|---|
| What it is | A store account with no subscription | A store account with Cloud | An account the owner set up |
| Gets in with | Sign in with Apple | Sign in with Apple | Email and password, as today. It can link Apple once (S-05, I-31). |
| The bank's authority | The phone | The server | The server, as today |
| The server holds | The account: an Apple user id, an email and its sessions. No study content. | The account and the whole bank | The account and the whole bank |
| Practice, Review, Terms, exams | Yes, with no network | Practice works offline; exams and adding sets need a connection, as today | As today |
| Follows the person to another device | No | Yes | Yes |
| Pays | Nothing | US$4.99 a month or US$29.99 a year | Nothing. The server grants it Cloud. |

A **store account** is one made by Sign in with Apple. On the server it is a `user` row whose origin is `store`, with an `account` row for Apple; the `account` table already carries a provider and that provider's account id (`apps/api/src/db/schema.ts:43-58`). Every account that exists today becomes `invited` (S-02).

One consequence to say plainly wherever the app or the listing describes Cloud: a paying Cloud user needs a connection for exams and for adding sets, and a free user does not. Exams start, take answers and end on the server (`QBank/Offline/OfflineStore.swift:54-55`).

## How the app knows which kind

Three facts decide it. The first two come from the server; the third is the phone's own.

1. **Origin**: `invited` or `store`, named by the account in a session (S-02).
2. **Cloud state**: whether the account has Cloud now, reported with the session and by the Cloud routes (S-03, S-07).
3. **Authority**: for a store account, which side holds the bank right now, `phone` or `cloud`. The phone records it durably beside the bank, and it changes only at the end of a hand-over that succeeded (below).

An invited account is always in server mode. For a store account the transport follows the recorded authority, never the Cloud state alone, because the two differ while a hand-over is still to do:

| Cloud state | Authority | Meaning | What the app does |
|---|---|---|---|
| Not active | `phone` | Free | Runs on the phone's bank |
| Active | `phone` | Cloud was just turned on | Hands the bank over to Cloud, then switches |
| Active | `cloud` | Cloud | Runs on the server's bank |
| Not active | `cloud` | Cloud ended | Hands the bank back to the phone, then switches |

When the server cannot be reached, the phone keeps its recorded authority and stays signed in, as today (`QBank/AppModel.swift:118-128`). A free user is not slowed by it.

## Who has Cloud

- **The server decides, in one gate (A5).** An invited account always has Cloud. A store account has it while Apple says its subscription is active. A store account without Cloud is refused on every content, answer, exam and import route with `cloud_required` (S-03).
- **The app never grants Cloud from what StoreKit says (A9).** It buys with StoreKit 2 and a token the server issued for the account, posts Apple's signed transaction to the server, and finishes the transaction only after the server answers active. The answer carries the whole Cloud state. App Store Server Notifications V2 keep the server current (S-08).
- **The plans**: one subscription group with a monthly and a yearly plan, at the prices above. No free trial. Family Sharing off. Billing grace on, so Cloud stays active while Apple retries a payment.
- **Deferred**: the App Store Server API (S-13). A missed renewal heals when the app next sends its current transaction.
- **The store release is version 0.2.0.**

### What a free account may still call on the server

The gate covers the bank, not the account. By the contract's own tags (`Packages/QBankKit/Tests/QBankKitTests/Fixtures/openapi.json`):

| Tags | A store account without Cloud |
|---|---|
| `Sign in`, `Account` (the session, sign-out, the color scheme, Delete account), and the Cloud routes | Allowed. The account lives on the server in every mode. |
| `Courses`, `Folders`, `Import`, `Delete`, `Attempts`, `Review`, `Exams`, `Progress` | `cloud_required`. On the phone these go to the local engine instead ([on-phone-bank.md](on-phone-bank.md)). |
| The bank archive download (S-09) | Allowed, so a bank can come back after Cloud ends |
| The bank archive upload (S-09) | Needs Cloud |
| `Make questions`, `Agent keys`, `Admin` | Off for every store account, with or without Cloud (below) |

So the color scheme is the account's and is saved on the server in every mode. Without a connection a pick is not saved and Settings says why, as today (`AppModel.swift:95-116`).

## Getting in

- **The first screen** offers Sign in with Apple, and below it a small "Use an existing QBank account" for email and password (A7). The Sign up screen leaves the iPhone app; invited sign-up stays on the web.
- **The server verifies Apple's identity token** against Apple's public keys: signature, issuer, bundle id, nonce, expiry (A6, S-04). No Apple secret is needed to sign people in.
- **Accounts are never linked by matching email.** An Apple email that already belongs to a password account is refused with a sentence that points to the email door. Linking is explicit, from Settings, while signed in (S-05, I-31).
- **The update signs nobody out.** A stored session opens the app signed in (`AppModel.swift:73-74`), and it is an invited account's session, so that phone stays in server mode with its saved copies and waiting answers.
- **As built (I-30).** `QBank/SignIn/WelcomeView.swift` is the first screen. The app makes a nonce and asks Apple with its SHA-256 (`AppleSignInNonce`); the identity token and the nonce go to `POST /api/sign-in/apple`, which takes no authorization code. A store account opens its bank on the phone. If the server cannot be reached, or answers 502 or 503, the bank opens anyway, Settings says the sign-in is waiting, and the app sends it again when the network returns, when it comes back to the front, and from Settings; a refusal then is said in Settings and the bank stays open. A 401, 409 or 429 at the first screen is said in plain words and signs nobody in, and a 409 opens the email door with the email filled in (`QBank/SignIn/AppleSignInWording.swift`).
- **The web app is unchanged (A8).** Email and password for invited accounts. No Sign in with Apple on the web, and no web access for store accounts, in the first release.
- **Deleting a store account** asks for a fresh Sign in with Apple, since the account has no password. The server exchanges its authorization code, revokes Apple's token, then deletes; no Apple token is stored at rest (A10, S-06). Today the route takes a password (`apps/api/src/routes/auth.ts:265-281`), and that stays for invited accounts.

## Moving a bank: the hand-over

### The rules

1. **One authority at a time (A3).** Exactly one side holds a store account's bank. There is no merging and no continuous sync. A move carries the whole bank as one bank archive ([on-phone-bank.md](on-phone-bank.md)).
2. **Counts are compared before every switch.** The three comparisons are in [on-phone-bank.md](on-phone-bank.md). The recorded authority changes only after they hold.
3. **The side being left is never deleted.** After a move to Cloud the phone's bank file stays on the phone as a dated safety copy. After a move back the server's bank stays on the server (how long is OD2, below). No pull request in this plan removes a safety copy on its own; only Delete account does (I-32).
4. **Any failure changes nothing.** The authority stays where it was, both sides keep what they had, and the app says that nothing was changed.
5. **A lease stops edits during a move.** The phone records that a move has started, and in which direction, before it reads the bank, and clears the record when the move ends either way. While it is set the bank takes no writes. It survives a relaunch: at launch the app finishes or abandons the move before anything else (I-34).
6. **Ids are kept.** A set, a question and an answer have the same id on both sides, which is what lets the phone tell which of its sets Cloud already has.

### Each moment

| Moment | What happens |
|---|---|
| Cloud turns on, and the account has no bank on the server | The phone writes its bank as an archive and uploads it in one request. The server stores it in one transaction and answers with counts. The phone compares them with its own, then records `cloud`. The phone's bank file becomes a safety copy. |
| Cloud turns on, and the server already has a bank: a second device, a returning subscriber, or an upload whose answer was lost | The server's bank is the authority. Nothing is uploaded and nothing is merged. The phone records `cloud`, and its bank file becomes a safety copy. If the phone holds sets that Cloud does not, the app says so and offers to add them as new sets. |
| Cloud ends: the subscription lapses, is refunded or revoked, or the person turns Cloud off | The phone downloads the whole bank, writes it to a fresh file, compares counts, then records `phone`. The server allows this download for an account whose Cloud has ended. |
| Any step fails | Rule 4 |

"No bank on the server" means that none of the archive's twelve tables holds a row of the account, deleted rows included (S-09).

### What follows from the rules

- **A lost answer needs no special case.** If an upload was stored but its answer never arrived, the next try is refused because the account now has a bank, and the second row of the table applies. The phone finds every one of its sets in Cloud, by id, so it has nothing to offer.
- **A first launch on a second device makes no phone bank.** When the server says Cloud is active at sign-in, the phone adopts the Cloud bank and the sample set is never added (I-22, I-35).
- **`cloud_required` is a signal, not an error to show.** A store account in server mode that is refused with `cloud_required` has lost Cloud: the app starts the hand-back, the way `AppModel.handle` already turns an ended session into a route change (`AppModel.swift:207-226`).
- **Waiting answers are never dropped by a hand-back.** In server mode practice answers given without a connection wait in a queue on the phone, and the queue discards an answer the server refuses with a 4xx (`Packages/QBankKit/Sources/QBankKit/Offline/AttemptQueue.swift:18-25`). After Cloud ends the server would refuse them with `cloud_required`. So a hand-back does not let the queue discard on that code. Once the fresh file is written it replays the waiting answers into the phone's bank through the local engine, which records an answer once per `clientAttemptId` as the server does, and only then clears them.
- **Work done on the phone after Cloud ended does not join a bank already on the server.** A returning subscriber whose earlier bank is still on the server gets that bank as the authority (the second row). Sets made on the phone since are offered as new sets. Answers given on the phone since, to sets that are in both, stay only in the safety copy. Whether a returning subscriber finds a bank on the server at all is OD2. I-35 must tell the person this before the switch.

### What each event does to the phone's files

| Event | The bank file | Safety copies | Saved copies and waiting answers of server mode |
|---|---|---|---|
| Sign out, free | Kept. It is the only copy. Signing in again as the same person opens it. | Kept | None exist |
| Sign out, Cloud or invited | None is active | Kept | Erased, as today (`AppModel.swift:183-190`) |
| Move to Cloud | Becomes a safety copy | Kept | Start empty |
| Move back to the phone | A fresh file, from the download | Kept | Waiting answers are replayed, then erased with the saved copies |
| Delete account | Erased, before the server account is deleted | Erased | Erased |
| Device backup and restore | In the backup (A12) | In the backup | Waiting answers are in the backup, saved copies are not, as today |

## What is off for store accounts

Free or Cloud, a store account does not get these in the first release. The server enforces each one; the app also does not show it. Rows in Settings follow what the account can do, not its role (I-20).

| Off | Why | Today, for reference |
|---|---|---|
| Make questions and exam twins | They send material to Anthropic and cost the owner money. Only an account the owner listed has them. | The server refuses every account not in `QUESTION_MAKER_ACCOUNTS` with `not_allowed` (`apps/api/src/routes/question-maker.ts:813`, `apps/api/src/config.ts:41-45`) |
| Connect an agent, and agent keys | Shown only to invited accounts in the first release | An unconditional row in Settings (`QBank/Settings/SettingsView.swift:117-121`) |
| The admin's frozen view | The owner can look at invited accounts only. The list, the view, the temporary password and Repair do not reach a store account (S-02). | The admin's view picks among all user accounts (`apps/api/src/auth/accounts.ts:185-203`) |
| The web app | No Sign in with Apple on the web (A8) | Email and password only |
| Change password, and the temporary password | A store account has no password | A row in Settings (`SettingsView.swift:112-116`) |
| Sign up in the app | The screen leaves the app (A7) | Gone since I-30; invited sign-up is on the web |
| Saved for offline, in free mode only | The whole bank is already on the phone | A row in Settings (`SettingsView.swift:337-345`) |

Cloud accounts keep Saved for offline, since their bank is on the server.

An invited account keeps everything it has today, and a build for the App Store is the same build. Before Make questions or exam twins is first used, the app asks once and names Anthropic (I-26).

## Still open

One question is the owner's and is not decided. Nothing here assumes an answer. OD1, the address of the privacy and support pages, is decided: https://qbank-app.dimitrygallego.com, served from `site/` ([ci.md](ci.md#public-pages-pagesyml)).

### OD2. The server's copy of a bank after a subscription ends

The bank goes back to the phone either way, so nobody loses their questions. What is open is the copy left on the server:

- keep it until the person deletes their account (the plan's recommendation for the first release), or
- delete it a fixed time after the subscription ends.

It decides two things workers will meet: what the privacy policy says (I-43), and which row of the hand-over table a returning subscriber lands in. With the copy kept, they land in "the server already has a bank", with the limits written above. With the copy deleted, they land in "no bank on the server" and the phone's bank is uploaded whole.

## Rules every pull request in this work carries

- Server changes are additive: a new route or field is safe; removing, renaming or narrowing one is not.
- The invited accounts' path is not edited to make room for the new one. New code sits beside it.
- The imported sets, folder names and progress of the accounts that exist today are never deleted, moved or renamed by any change.
- This repository holds no backend source, no `.sql` file, no folder named `migrations`, `deploy` or `infra`, no credentials and no third-party code (`test/release-checks.sh:1047`), and at most 1,000 code lines a file.
- Tests never use a real account, real credentials or the production server: the fake server and scripted fakes, through the Debug launch seam only ([testing.md](testing.md)).
