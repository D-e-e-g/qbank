# Accounts and Cloud

The design record for who is signed in, where their question bank lives, and how a whole bank moves between the phone and the server. [on-phone-bank.md](on-phone-bank.md) is its other half: the bank on the phone and the bank archive format.

This is a record to build to, not a description of shipped code. Only Getting in (I-30, linking Apple in Settings, I-31, and deleting a store account, I-32), the Cloud purchase (I-33), the move to Cloud (I-34), and Cloud ending and a second device (I-35) exist so far, and their sections say what was built. The combine of two banks ([Combining two banks](#combining-two-banks)) is designed here (I-36): the server's part is live (S-14, S-15, S-16), the phone keeps the time of last change and the archive's stamp (I-37), and the combine itself is not built (I-38, I-39). Statements about today's code name the file and line; they were read at app commit `45ec726` and server commit `b913bcc` (`D-e-e-g/qbank-server`, whose paths start with `apps/` or `packages/`), and those in Combining two banks at app commit `254937b` and server commit `d86a61f`.

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
| Not active | `phone` | Free | Runs on the phone's bank. When the server holds a bank this phone has not taken in, combines it into the phone's |
| Active | `phone` | Cloud was just turned on | Moves the bank to Cloud, or combines it with the bank the server holds, then switches |
| Active | `cloud` | Cloud | Runs on the server's bank |
| Not active | `cloud` | Cloud ended | Hands the bank back to the phone, then switches |

When the server cannot be reached, the phone keeps its recorded authority and stays signed in, as today (`QBank/AppModel.swift:234-251`). A free user is not slowed by it.

## Who has Cloud

- **The server decides, in one gate (A5).** An invited account always has Cloud. A store account has it while Apple says its subscription is active. A store account without Cloud is refused on every content, answer, exam and import route with `cloud_required` (S-03).
- **The app never grants Cloud from what StoreKit says (A9).** It buys with StoreKit 2 and a token the server issued for the account, posts Apple's signed transaction to the server, and finishes the transaction only after the server has recorded it or refused it for good. The answer carries the whole Cloud state. App Store Server Notifications V2 keep the server current (S-08).
- **The plans**: one subscription group with a monthly and a yearly plan, at the prices above. No free trial. Family Sharing off. Billing grace on, so Cloud stays active while Apple retries a payment.
- **As built (I-33).** Settings shows a Cloud row to a store account with a session on the server (`QBank/Cloud/CloudSection.swift`). It opens the plans sheet (`CloudPlansView`): each plan's name, period and price as StoreKit gives them, the renewal terms, the privacy policy and the terms of use (`LegalLinks`), and Restore purchases; once Cloud is on, the sheet says until when and offers Manage subscription. `CloudModel` buys with the account's `storeToken` from `GET /api/me/cloud` as the appAccountToken, posts the signed transaction to `POST /api/me/cloud/transactions`, and finishes it once the server has handled it for good: any 200, whether Cloud is then active or not (a refund, a revocation or an ended period leaves it off), or a 400 or 409 refusal, said in the server's words. Only an answer that may change (no connection, a 5xx, a 429, or a 401 until the account signs in again) leaves it unfinished, and the app sends it again: StoreKit hands an unfinished transaction over again at launch, and opening Settings sends every unfinished one. Restore reads the Apple Account's current subscriptions whether they are finished or not, so finishing one never loses Cloud. An invited account is not offered Cloud. A purchase or Restore that the server answers with Cloud active starts the move of the bank to Cloud (I-34, below). `StoreKit/QBankCloud.storekit` sells the two plans to a run from Xcode and never ships ([testing.md](testing.md)).
- **Deferred**: the App Store Server API (S-13). A missed renewal heals when the app next sends its current transaction.
- **The store release is version 0.2.0.**

### What a free account may still call on the server

The gate covers the bank, not the account. By the contract's own tags (`Packages/QBankKit/Tests/QBankKitTests/Fixtures/openapi.json`):

| Tags | A store account without Cloud |
|---|---|
| `Sign in`, `Account` (the session, sign-out, the color scheme, Delete account), and the Cloud routes | Allowed. The account lives on the server in every mode. |
| `Courses`, `Folders`, `Import`, `Delete`, `Attempts`, `Review`, `Exams`, `Progress` | `cloud_required`. On the phone these go to the local engine instead ([on-phone-bank.md](on-phone-bank.md)). |
| The bank archive download (S-09) | Allowed, so a bank can come back after Cloud ends |
| The bank archive upload (S-09) and the combine (`POST /api/me/bank/combine`, S-15) | Needs Cloud |
| `Make questions`, `Agent keys`, `Admin` | Off for every store account, with or without Cloud (below) |

So the color scheme is the account's and is saved on the server in every mode. Without a connection a pick is not saved and Settings says why, as today (`AppModel.swift:203-232`).

## Getting in

- **The first screen** offers Sign in with Apple, and below it a small "Use an existing QBank account" for email and password (A7). The Sign up screen leaves the iPhone app; invited sign-up stays on the web.
- **The server verifies Apple's identity token** against Apple's public keys: signature, issuer, bundle id, nonce, expiry (A6, S-04). No Apple secret is needed to sign people in.
- **Accounts are never linked by matching email.** An Apple email that already belongs to a password account is refused with a sentence that points to the email door. Linking is explicit, from Settings, while signed in (S-05, I-31).
- **The update signs nobody out.** A stored session opens the app signed in (`AppModel.swift:139-155`), and it is an invited account's session, so that phone stays in server mode with its saved copies and waiting answers.
- **As built (I-30).** `QBank/SignIn/WelcomeView.swift` is the first screen. The app makes a nonce and asks Apple with its SHA-256 (`AppleSignInNonce`); the identity token and the nonce go to `POST /api/sign-in/apple`, which takes no authorization code. A store account opens its bank on the phone. When the server cannot be reached (no connection, or a cancelled request), answers with a status of 500 or above, or sends an answer the app cannot read, the bank on the phone opens anyway, Settings says the sign-in is waiting, and the app sends it again when the network returns, when it comes back to the front, and from Settings. Every other answer at the first screen is a refusal said in plain words that signs nobody in: a 400 `invalid_request`, a 401 `invalid_apple_token`, a 409 `password_account` or `email_in_use` (which opens the email door with the email filled in), and a 429 with the minutes to wait. A resend keeps waiting, and is sent again, after a 429, a 5xx, a dropped connection or an answer that cannot be read. Any other answer to a resend is a refusal: Settings says it, the kept sign-in is dropped, the app stops sending it on its own, and Settings says this phone is not connected to the QBank service yet and asks for a new Sign in with Apple, or a sign-out to use an existing QBank account; the bank on the phone stays open and untouched (`QBank/SignIn/AppleSignInWording.swift`).
- **As built (I-31).** Settings offers Sign in with Apple to an account whose ways in, the session's `signInWith`, include `password`, which only an invited account has (`QBank/Settings/LinkAppleModel.swift`). It asks for the account's current password, then for a Sign in with Apple with a fresh nonce, and sends the identity token, the nonce and the password to `POST /api/me/apple`. The answer is the account with `apple` among its ways in: the phone keeps it in the stored session, and the row and its screen then say Sign in with Apple is linked. Nothing else changes: the bank stays on the server, the email and password keep working, and the session stays. From then on Sign in with Apple on the first screen opens that account, on the server, as its password does. Every refusal the route documents is said in plain words that say nothing was linked and what to do next, and keeps the person signed in: a wrong password, a token Apple did not confirm, an Apple identity that is another account's (`apple_linked_elsewhere`), another identity already linked to this account (`apple_already_linked`, after which the phone reads the session again to show it), a lock with the minutes to wait, and the server being unable to check or to link. An ended session signs out and a temporary password asks for a new one, as everywhere. There is no unlinking in the app; the route that unlinks (`DELETE /api/me/apple`) is not used.
- **The web app is unchanged (A8).** Email and password for invited accounts. No Sign in with Apple on the web, and no web access for store accounts, in the first release.
- **Deleting a store account** asks for a fresh Sign in with Apple, since the account has no password. The server exchanges its authorization code, revokes Apple's token, then deletes; no Apple token is stored at rest (A10, S-06). An invited account still deletes with its password, on the same route. **As built (I-32)**, free or Cloud alike: Settings > Delete account first checks the session with `GET /api/session`, so a server that cannot be reached, or a session it ended, stops the delete before anything is erased; then it asks Apple, and a yes from any Apple Account but the one signed in erases nothing. Then, in this order, it keeps a record of the delete with the session in the keychain, erases this phone's copy (`Banks/<Apple's id>/` with anything kept beside it, the saved courses and waiting answers under `Accounts/<account id>/`, and the sets being written), sends `DELETE /api/me` with the identity token, the nonce and the authorization code, and clears the keychain. The record says which step is done, so a delete that stops after the erase began leaves the app offering to finish it or to sign out, also after a relaunch (signing out keeps the account on the server until it is deleted later from Settings), and a try never repeats a step that is done. Each try asks Apple afresh, since a token and a code are good once. The server deletes only the account this phone's session belongs to, and that session goes with it: a try that finds the session gone forgets it and says so, rather than deleting anything again. The screen says that deleting does not cancel a QBank Cloud subscription and offers Manage subscription (`QBank/Settings/AppleDeleteAccountView.swift`). For a Cloud account the erase takes the safety copy and its hand-over record with the rest of `Banks/<Apple's id>/`, and no move to Cloud, hand-back or adoption of QBank Cloud's bank begins while a delete runs, since writing the bank's record or a fresh file would bring back the folder the erase removes (`AppModel.bankMove()`, `bankHandBack()`, `bankAdoption()`).

## Moving a bank: the hand-over

### The rules

1. **One authority at a time, and one bank when two meet (A3).** Exactly one side holds a store account's bank at any moment, and there is no continuous sync. A move to a server with no bank, and the way back once Cloud ends, carry the whole bank as one bank archive ([on-phone-bank.md](on-phone-bank.md)). When the phone's own bank meets a bank on the server (Cloud turns on, or Cloud is not active and the server holds a bank the phone has not taken in, as for a new iPhone that signs in to a lapsed account), the phone combines the two item by item: a row changed on both sides keeps the later change, every answer is kept once, nothing is removed, and nothing switches until the checks pass. The app does this without asking first, then shows exactly what was combined ([Combining two banks](#combining-two-banks)). When Cloud ends for a bank that is in Cloud, Cloud's bank already holds everything from the phone's earlier file, so it comes back whole.
2. **The checks pass before every switch.** A move and a hand-back compare counts, by the three comparisons in [on-phone-bank.md](on-phone-bank.md). A combine passes [checks A to C](#the-checks-before-a-switch), and D when Cloud stores it. The recorded authority changes only after they hold.
3. **Nothing is deleted.** The side being left is never deleted, and a combine removes no row on either side. After a move or a combine up, the phone's bank file stays on the phone as a dated safety copy. After a move back the server's bank stays on the server (how long is OD2, below). Every earlier copy of a bank stays on the phone: clearing older ones (I-47) is not built for launch and can follow in a later update. Only Delete account removes them (I-32).
4. **Any failure changes nothing.** The authority stays where it was, both sides keep what they had, and the app says that nothing was changed. One exception: when the server stored a combine and the switch did not follow (the answer lost, counts that differ, a record that cannot be written), Cloud's bank already holds the phone's items. Nothing is removed by that, the phone keeps using its own bank, and the next try combines the two again and finds nothing of that upload left to add.
5. **A lease stops edits during a move.** The phone records that a move has started, and in which direction, before it reads the bank, and clears the record when the move ends either way. While it is set the bank takes no writes. It survives a relaunch: at launch the app finishes or abandons the move before anything else (I-34). A combine holds the same lease, in its direction, and one the app was closed during runs again.
6. **Ids are kept.** A set, a question and an answer that moved have the same id on both sides, which is how a combine knows them again. Where two rows are the same item under two ids, the server's id is kept: a row on the server is never given a new one (ID-18).

### Each moment

| Moment | What happens |
|---|---|
| Cloud turns on, and the account has no bank on the server | The phone writes its bank as an archive and uploads it in one request. The server stores it in one transaction and answers with counts. The phone compares them with its own, then records `cloud`. The phone's bank file becomes a safety copy. |
| Cloud turns on, and the server already has a bank | A phone with no bank of its own (a first launch on a second device) uses Cloud's, and no file is made. A phone that holds its own bank [combines up](#combine-up), then records `cloud`, and its bank file becomes a safety copy: a second device with its own bank, a returning subscriber, also one whose phone has newer work than the server, or an upload whose answer was lost. |
| Cloud ends: the subscription lapses, is refunded or revoked, or the person turns Cloud off | The phone downloads the whole bank, writes it to a fresh file, compares counts, then records `phone`. The server allows this download for an account whose Cloud has ended. |
| The bank on the phone is in use, Cloud is not active, and the server holds a bank this phone has not taken in: a new iPhone that signs in to a lapsed account, or a phone whose combine up was still to do when Cloud ended | The phone [combines down](#combine-down), into a fresh file, then records `phone` in that file. Settings keeps offering it until it is done. |
| Any step fails | Rule 4 |

"No bank on the server" means that none of the archive's twelve tables holds a row of the account, deleted rows included (S-09). `GET /api/me/cloud` then answers a null `bankStamp` (S-16).

### What follows from the rules

- **A lost answer needs no special case.** If an upload was stored but its answer never arrived, the next try finds that the account has a bank, and combines up. Every row of the upload is on both sides under one id, so nothing is added twice.
- **A first launch on a second device makes no phone bank.** When the server says Cloud is active at sign-in, the phone adopts the Cloud bank and the sample set is never added (I-22, I-35).
- **`cloud_required` is a signal, not an error to show.** A store account in server mode that is refused with `cloud_required` has lost Cloud: the app starts the hand-back, the way `AppModel.handle` already turns an ended session into a route change (`AppModel.swift:480-498`).
- **Waiting answers are never dropped by a hand-back.** In server mode practice answers given without a connection wait in a queue on the phone, and the queue discards an answer the server refuses with a 4xx (`Packages/QBankKit/Sources/QBankKit/Offline/AttemptQueue.swift:18-25`). After Cloud ends the server would refuse them with `cloud_required`. So a hand-back does not let the queue discard on that code. Once the fresh file is written it replays the waiting answers into the phone's bank through the local engine, which records an answer once per `clientAttemptId` as the server does, and only then clears them.
- **Work done on the phone after Cloud ended joins the bank on the server.** A returning subscriber whose earlier bank is still on the server combines up: the phone's newer rows win by time, and every answer is kept. Whether a returning subscriber finds a bank on the server at all is OD2.
- **Two devices that both changed during a lapse each combine up in turn.** The later change wins item by item and every answer is kept, whichever device goes first.

### What each event does to the phone's files

| Event | The bank file | Safety copies | Saved copies and waiting answers of server mode |
|---|---|---|---|
| Sign out, free | Kept. It is the only copy. Signing in again as the same person opens it. | Kept | None exist |
| Sign out, Cloud or invited | None is active | Kept | Erased, as today (`AppModel.swift:454-462`) |
| Move to Cloud, or combine up | Becomes a safety copy | Kept | Start empty |
| Move back to the phone | A fresh file, from the download | Kept | Waiting answers are replayed, then erased with the saved copies |
| Combine down | A fresh file, holding the combined result. The file before it is kept. | Kept | None exist |
| Delete account | Erased, before the server account is deleted | Erased | Erased |
| Device backup and restore | In the backup (A12) | In the backup | Waiting answers are in the backup, saved copies are not, as today |

### As built (I-34)

The move to Cloud. The second device, the lost answer and Cloud ending are in As built (I-35), below.

- **When it starts.** A purchase or Restore in the plans sheet that the server answers with Cloud active, for a free account, closes the sheet and starts the move once it has closed, or at once if the person closed it first (`QBank/Cloud/CloudMoveModel.swift`). A purchase the App Store approves later, outside the sheet, does not start it. While Cloud is on and the bank is still on the phone, the plans sheet and Settings offer "Move my bank to QBank Cloud". An invited account is never offered it.
- **The record.** The authority and the lease are kept beside the bank, in `Banks/<key>/handover.json`, written atomically with the bank's file protection (`Packages/QBankKit/Sources/QBankKit/Handover/BankHandover.swift`). No file means `phone`. A record the app cannot read is refused and left as it is, and the bank does not open.
- **The move** is `BankMoveToCloud` (`Packages/QBankKit/Sources/QBankKit/Handover/BankMoveToCloud.swift`): record the lease, hold the bank's writes, write the archive, upload it with `PUT /api/me/bank` (a 120 second timeout), then compare the server's counts with the archive's and with a fresh count of the phone's store, table by table, on all twelve keys. Only then does it record `cloud`. Every other ending records `phone` with no lease and gives the writes back: no connection, a timeout, a dropped connection, a refusal (`bank_not_empty`, `cloud_required`, `invalid_archive`, `archive_too_large`), a 5xx, an answer that cannot be read, and counts that differ. The move's screen covers the app while it runs and says the outcome in plain words; a refusal is said in the server's sentence. It offers to try again only where that may end differently: not after a refusal or counts that differ, since the server then holds a bank for the account or refuses this one.
- **The lease survives a relaunch.** A launch, or a Sign in with Apple, that finds it holds the bank's writes, does not file the sample set, and runs the whole move again before anything else, since the earlier upload may or may not have arrived. While it is held, a write to the bank is refused with `bank_moving`.
- **The safety copy is the bank file itself.** It stays where it was, `Banks/<key>/bank.sqlite`, byte for byte as before the move, and is never opened again in Cloud mode, so no schema step runs on it. The record's `movedToCloudAt` dates it. The plan said "a dated safety copy"; a copy under a dated name would be a second file to write and keep, and the untouched original is safer.
- **After the switch** the account is a store account on the server (`AccountKind.store`): the bank's requests go to the server, the account gets saved copies and waiting answers as any account on the server, and what the phone keeps for the person (drafts, the key of the bank) stays under Apple's user identifier. A launch, or a Sign in with Apple, that finds `cloud` opens the account on the server. If the server cannot be reached at a Sign in with Apple, the app says so and signs nobody in, rather than open the safety copy.
- **A refusal because the account already has a bank** (`bank_not_empty`), including an upload whose answer was lost, changes nothing and leads to the server's bank (As built (I-35)). The [combine](#combining-two-banks) takes the place of what follows there (I-39).

### As built (I-35)

Cloud ending, a second device, a returning subscriber and the lost answer. An invited account's path is untouched: none of this reaches it. The hand-back, its record, the waiting answers, the second device with no bank and the counts the screens show stay under the [combine](#combining-two-banks), and so does reading the server's bank into memory without writing anywhere (`BankAdoption.look`). The offers, and the screens that ask before using or bringing a bank, are replaced by it ([below](#replaced-by-the-combine-i-39)).

- **When the bank comes back.** For a store account whose record says `cloud`, the server saying Cloud is not active starts the hand-back (`QBank/Cloud/CloudReturnModel.swift`): the session at launch or at a Sign in with Apple, Cloud's state (`GET /api/me/cloud`), or any request refused with `cloud_required`. It starts on its own once per launch. When it fails and the person closes it, Settings offers "Bring my bank back to this iPhone", and a screen refused with `cloud_required` says that, instead of the server's sentence. A launch with no connection runs on the saved copies until the server can say. There is no switch in the app that turns Cloud off: a subscription cancelled in the Apple Account ends when its period does, and the server then says so.
- **The hand-back** is `BankHandBack` (`Packages/QBankKit/Sources/QBankKit/Handover/BankHandBack.swift`), on I-34's record, lease, archive and count comparison. It makes a fresh, empty file in the bank's folder under a dated name no file there has (`bank-<UTC time>.sqlite`), records a lease naming it, downloads the whole bank with `GET /api/me/bank`, reads it into the fresh file whole or not at all (the archive reader's own checks), counts the fresh file again and compares it with the archive on all twelve keys, keeps the waiting answers in it (below), and only then records `phone`, in that file, with the same write that clears the lease. Every other ending takes away the fresh file it made, and only that file, and writes the record back as it was: no connection, a timeout, a dropped connection, a refusal, a 5xx, a download cut off or not a bank archive, counts that differ, and a record that cannot be written. A lease found at launch is a hand-back the app was closed during: its file is taken away and the record keeps `cloud`. The I-34 safety copy and every earlier file stay byte for byte as they were, and nothing deletes the server's copy.
- **The record, version 2.** It names the file the bank is in (`bankFile`, `bank.sqlite` until a hand-back), when it came back (`returnedAt`), the sets offered to the bank in use (`offeredSets`, below) and the file that holds them (`offeredFile`), and the file a hand-back's lease is writing. A version 1 record reads as one whose bank is in `bank.sqlite`. A record naming anything but a bank file is refused, as an unreadable one is. The plan said the bank comes back into "a fresh file"; the first file keeps its name and each later one is dated, so no file is ever renamed or written over. The [combine](#combining-two-banks) drops `offeredSets` and `offeredFile` from the record, and has it name the server's bank last taken in (I-39).
- **Waiting answers.** An answer refused with `cloud_required` waits in the queue like one sent without a connection (`AttemptQueue.keepsWaiting`). The hand-back records every waiting answer in the fresh file through the local engine before the switch; an answer the engine refuses for good, as the server would, is left out, as the queue leaves out one the server refuses, and any other failure stops the hand-back. After the switch, any that came meanwhile are recorded too, and only then are the saved copies and waiting answers of server mode erased.
- **A second device.** A Sign in with Apple the server answers with Cloud active, for a person with no bank and no record on this phone, records `cloud` and makes no bank file, so no sample set either.
- **What the screens count.** The move, the hand-back and the screen that offers QBank Cloud's bank show the bank as the person counts it (`BankSummary`): the sets they can open, the questions in them, and every answer. A set's earlier versions and deleted sets are left out of those numbers, never out of the comparison, which is of every row of the twelve tables.

#### Replaced by the combine (I-39)

The app still does what these say until I-39 merges. None of it is the design: do not build on it. I-39 removes `BankOffer`, the switch in `BankAdoption.adopt`, the screens that offer QBank Cloud's bank and its sets, and "Bring it to this iPhone" with "Not now". Their Settings rows become one, shown only while a combine is still to do.

- **A bank here, and QBank Cloud holds one.** After such a sign-in for a person whose bank is on this phone, or when QBank Cloud refuses the move with `bank_not_empty` (a returning subscriber, or an upload whose answer was lost), the app reads QBank Cloud's bank without writing anything anywhere (`BankAdoption.look`, `Packages/QBankKit/Sources/QBankKit/Handover/BankAdoption.swift`). When it holds anything, a screen says what it holds, how many sets only this phone has, and that answers given here to sets in both stay only in the safety copy (`QBank/Cloud/CloudAdoptModel.swift`). Nothing is uploaded or merged. Only "Use my bank in QBank Cloud" switches: one write of the record, `cloud`, naming the sets offered, and the bank file becomes the safety copy with its writes held. "Not now" leaves the bank on this phone, and Settings offers QBank Cloud's bank in place of a move that would be refused again. A sign-in whose look fails asks nothing; the move, offered in Settings, finds the same.
- **Which sets QBank Cloud holds.** A set on this phone is in QBank Cloud when one of Cloud's sets, of any version, deleted or not, has its lineage, as a set that moved between the two has, or its very file, as the same file imported on each side has. After a lost answer every set is there, so nothing is offered.
- **Adding what only this phone has.** Only on a tap: "Add it to QBank Cloud" right after the switch, or "Add sets from this iPhone" in Settings later. Each set is rebuilt as a question file from the safety copy, opened only to read, as the server rebuilds a set to check an archive (`BankOffer`), and imported through `POST /api/imports` with `decision: separate`: into the course of the same code in the same semester, whatever its title, or the topic of the same title (ignoring case; one that is archived is named all the same, so the import asks to unarchive it rather than refuse a second of that name), or a new one, into the folder of the same name, and beside any set of the same name, never in its place. Nothing on either side is removed or renamed. The record stops offering each set as soon as it went, so a set that went before an import failed, a sign-out or the app closing is never added twice, and it keeps offering any set that did not go. A course or topic that one import made is read back before the next set, so the sets of one place go into one.
- **Sets still offered when Cloud ends.** The hand-back keeps them offered, from the file that holds them, now the earlier copy beside the fresh file. Settings offers "Add sets from this iPhone's earlier copy", and a tap adds them to the bank on this phone the same way, through the local engine's own import, `decision: separate`, into the course or topic and folder of the same name. Nothing is added on its own, nothing is removed or renamed, and the earlier file is opened only to read. The offer carries through one hand-back and one move: a later move to Cloud keeps offering them, then to QBank Cloud. A second offer, made when this phone takes QBank Cloud's bank again or QBank's bank comes in place of the one here, replaces an earlier one still pending; the earlier file stays on the phone, untouched, but the app no longer offers its sets. Once sets are added, the screens under the Cloud screen start afresh and read the bank as it is now.
- **A new device after Cloud ended.** A Sign in with Apple the server answers with Cloud not active, for a person with no bank and no record on this phone, opens a new bank with the sample set, as for anyone without Cloud. The app then reads the account's bank on the server without writing anything (`GET /api/me/bank`, which the server allows a lapsed account). When it holds anything, one screen says so, with its counts, says that answers given here to sets in both stay only in the earlier copy, and offers "Bring it to this iPhone" or "Not now" (`QBank/Cloud/CloudReturnModel.swift`). Bring runs the hand-back with `BankHandBack(replacing:)`: the same fresh file, lease, download and twelve-table comparison, with the new bank's writes held while it runs, and only then records `phone` in the fresh file. The sets of the new bank that the server's bank does not hold (the sample set, unless the server's bank has it) are offered from that earlier file, as above. Not now keeps the new bank, and Settings offers "Bring my bank to this iPhone" while QBank stays open; once QBank is closed the offer is gone, and the new bank stays in use. After Bring, the screens under the Cloud screen start afresh on the bank that came down. A look that fails asks nothing. Nothing on the server is changed or deleted either way.

## Combining two banks

When the phone's own bank and a bank on the server meet, they become one that holds everything from both. This section is the rule set the pull requests that build it work to. The server's part is live: the time of last change on bank rows and the stamp on the download (S-14), `POST /api/me/bank/combine` (S-15), and `bankStamp` and `combinePaused` on `GET /api/me/cloud` (S-16); [on-phone-bank.md](on-phone-bank.md#a-combined-bank) says what each carries. On the phone the time of last change and the archive's stamp are built (I-37); the rest of the app's part is not: the combine itself, `BankCombine` (I-38), and the two flows, their screens, the receipt and the pause (I-39).

### Where it runs

**The phone combines, and the server stores.** The rules are written once, in `Packages/QBankKit`, and tested on the Mac with no simulator. The one step is `combine(into: R, from: I)`: R is a fresh store holding the server's bank as downloaded, and I is the phone's own bank, opened only to read. A combine never writes the person's own file.

It runs on the phone because it must work for an account without Cloud, which may download its bank but store nothing (`apps/api/src/cloud/gate.ts`). A combine on the server would also need a second copy of the rules, and would send a free account's bank to the server. So the server only stores a result, and refuses one that would lose a row. An invited account's bank is only ever on the server, so it is never combined: the route refuses it with `not_store_account`.

### Combine up

Cloud is active, the record says `phone`, and the server holds a bank.

1. Record the lease and hold the bank's writes, as a move does (`Packages/QBankKit/Sources/QBankKit/Handover/BankMoveToCloud.swift`).
2. Download the server's bank (`GET /api/me/bank`). It carries a **stamp**, a fingerprint of the bank the server holds, which the phone only sends back or compares for equality.
3. Read it into a scratch store, as the app reads it to look at it (`Handover/BankAdoption.swift`).
4. Combine the phone's bank into the scratch store. The phone's file is only read.
5. Run checks A, B and C on the scratch store.
6. Send the scratch store as one archive, with the stamp, to `POST /api/me/bank/combine`.
7. The server stores it only if its bank still has that stamp, the archive holds every row the server holds, and no row both hold arrives changed with an earlier time. It answers its counts.
8. Check D: compare the server's counts with the scratch store's.
9. Only then record `cloud`. The phone's file stays as it was, as the safety copy.

Every ending but step 9 records `phone` with no lease and gives the writes back. A failure before the server stores the result changes nothing anywhere; one after it is rule 4's exception. A `bank_changed` refusal means another device wrote meanwhile: the combine starts again at step 2. Any other refusal ends the try, and a later try starts from a new download.

### Combine down

Cloud is not active, the record says `phone`, and the server holds a bank this phone has not taken in.

It runs the hand-back's own steps (a fresh dated file, a lease naming it, the bank on the phone holding its writes, the download, the read, the comparison with the archive; `Handover/BankHandBack.swift`), then combines the phone's bank into the fresh file, runs checks A, B and C, and only then records `phone` in the fresh file. Any failure removes only the fresh file. Nothing is sent to the server.

### When it starts, and the pause

- **Both start on their own.** The app does not ask first, and there is no "Not now".
- **What the phone has not taken in.** `GET /api/me/cloud`, which an account without Cloud may call, answers the stamp of the account's bank, `bankStamp`, so the phone learns at any launch, without a download, whether the server holds a bank. The record names the stamp of the bank last taken in, which a hand-back and a combine down write with their switch. A bank under any other stamp is one the phone has not taken in.
- **While a combine is still to do**, after a failure or during a pause, Settings offers it in one row.
- **The pause.** `GET /api/me/cloud` answers `combinePaused`, so the server can stop combining with no app update. While it is true the phone starts no combine, in either direction, and switches nothing. The combine route does not refuse for it: holding off is the phone's job. A move and a hand-back are not combines and go on.

### After a combine

- **The app shows exactly what was combined**, in the person's own counts (`Handover/BankSummary.swift`): what the server's bank held, what the phone's held, what was in both, and what the one bank now holds. Where WIN-14 kept a name, it says so. The screens and their wording are I-39's, to the wording approved in the release plan.
- **A receipt of each combine is kept beside the bank** on the phone: what was joined, and the counts. The combine works both out for its checks. Delete account erases it with the bank's folder.
- **Every earlier copy of the bank stays on the phone** (rule 3).

### The rule ids

Every row of the two tables below has an id: `ID-n` says when two items are the same, and `WIN-n` which side wins. **Tests cite the ids**: each rule has at least one test in `BankCombineTests` that names it (I-38). An id is never reused or renumbered, and a new rule takes the next number. A person approves the two tables before I-38 is built.

### Identity: when two items are the same

The same id means the same item. Where ids differ, the rules a bank already keeps within itself decide: two rows that match on one of the names below cannot both be live in one bank.

Rows are matched from the top of the table down, so a rule reads the pairs made above it. Ids are matched first, and each such pair is settled by the conflict rules. A name rule then pairs a row only the phone has with a server row of that name, as the row is named once settled, also a server row already paired by id. Two rows of the server's bank are never joined.

| Id | Item | The same when | Comes from |
|---|---|---|---|
| ID-1 | Semester | Same `id`, or same `number` (1 to 3) | One of each number per account: `semester_owner_number` (`apps/api/src/db/owner-migration.ts:34`) |
| ID-2 | Course | Same `id`, or same semester and same `code`, ignoring case, neither deleted | The code is unique in a semester (`apps/api/src/content/courses.ts:60`) |
| ID-3 | Topic | Same `id`, or same `title`, ignoring case, neither deleted | The index `course_topic_title` (`apps/api/src/db/deletion-migration.ts:35`, `Packages/QBankKit/Sources/QBankKit/Store/Schema/BankTablesStep.swift:183`) |
| ID-4 | Page | Same `id`, or same course and same `name`, ignoring case, neither deleted | The page name check, which does not count a deleted page (`apps/api/src/content/folders.ts:384`) |
| ID-5 | Folder | Same `id`, or same course, same list (one page's folders, or those on no page) and same `name`, ignoring case, neither deleted | `folder_name_in_list` and `assertNameFree` (`apps/api/src/db/schema.ts:338`, `apps/api/src/content/folders.ts:462`, `BankTablesStep.swift:180`) |
| ID-6 | Set, one version | Same `id` | A move keeps ids (rule 6) |
| ID-7 | Set, all its versions | Same `lineageId`. The set's versions are those of both sides. | `apps/api/src/db/schema.ts:199` |
| ID-8 | Set, imported apart on each side | Same `fileHash`, same `kind`, same course and folder once the rows above are paired, one version on each side, neither deleted, one such set on each side, and every question and term of each has its pair in the other (ID-10, ID-12) | The file hash is the same on both sides (`apps/api/src/content/hash.ts:4-6`, `LocalBank/ImportHash.swift:7`) |
| ID-9 | Question | Same `id` | A move keeps ids |
| ID-10 | Question, in two sets joined by ID-8 | Same `position` and same `contentHash` | The content hash is byte for byte the same on both sides (`apps/api/src/content/hash.ts:9-26`, `ImportHash.swift:10`) |
| ID-11 | Term | Same `id` | A term never changes after import |
| ID-12 | Term, in two sets joined by ID-8 | Same `key` | A set names each key once (`apps/api/src/bank/check.ts`) |
| ID-13 | Sitting or exam | Same `id` | One event on one device |
| ID-14 | Answer | Same `id`, or same `clientAttemptId`, the id the device chose | Unique per account on the server and in the phone's store (`apps/api/src/db/schema.ts:404`) |
| ID-15 | Progress | Same question lineage. It is worked out again, never merged (WIN-10). | `rebuildProgress` (`apps/api/src/progress/service.ts:852`), `LocalBank/ProgressRebuild.swift` |
| ID-16 | Hand clear from Review | Same question lineage | It has its own time, `clearedAt` (`apps/api/src/db/schema.ts:440`) |
| ID-17 | Course last used | The bank's one row | It has its own time, `updatedAt` (`apps/api/src/db/schema.ts:456`) |
| ID-18 | A pair under two ids | The result keeps the server's id, and for sets joined by ID-8 the server's lineages. Every reference of the phone's rows to the pair is pointed at it, in a column or inside a json field (a sitting's `questionIds`, `seededQuestionIds` and `examFolderIds`, and the question and folder ids in its `score`). A row on the server is never given a new id. | The server refuses an upload that lacks a row it holds |

ID-8 joins only that safe case. Otherwise (different folders, or a side that replaced the set) both sets are kept where they were: joining them would move a set. The server refuses a new question or term in a set it holds, which is why every one must pair. The sample set is the common case: each new phone files it through its own import (`LocalBank/SampleSetFiling.swift:14`), so every phone gives it its own ids and the same file hash.

### Conflicts: which side wins

**The later change wins, row by row.** When a row last changed is its `updatedAt` ([the time of last change](on-phone-bank.md#the-time-of-last-change)). It is the person's own last word, one rule a person can be told in a sentence, and two phones end with the same content whichever combines first.

| Id | What happened | On one side only | On both sides |
|---|---|---|---|
| WIN-1 | A row both banks hold differs | The change is kept: that side's row is newer. | The later change wins, whole row. A row with no time of last change has the time it was made. Equal times, or none (terms and answers never change): the server's row stands. A field fixed when the row was made is always the server's. |
| WIN-2 | Made new | It is kept, under its id. | Made under the same name (ID-1 to ID-5): they are one, under the server's id, with what each side put in it. Its fields follow WIN-1. |
| WIN-3 | Renamed (semester, course, topic, page, folder) | The rename is kept. | The later rename wins. |
| WIN-4 | Moved (a set to another folder, a folder to another page, a course to another semester) | The move is kept. | The later move wins. Every version of a set moves together, a version only one side has too. |
| WIN-5 | Reordered (folders in a list, topics) | The order is kept. | The later reorder wins. Items only one side has go after the others, in their own order. No order number of an item the other side already had is changed. |
| WIN-6 | Edited (a set replaced by a new version, or Restore) | Both versions are kept as versions of the one set. The newer one is current. | Both new versions are kept. Exactly one is current: the current row that changed later (WIN-1). The other has the latest `replacedAt` of the earlier versions, so Restore brings it back. A question whose content did not change keeps its answers from both sides, by content hash (`apps/api/src/content/import-set.ts:215`). |
| WIN-7 | Deleted (a set, a folder with its sets, a page, a course or topic, a past exam) | It stays deleted, with Undo for what is left of its 30 days. | It stays deleted. |
| WIN-8 | Deleted on one side, changed on the other | - | The later of the two wins: a change after the delete brings the row back, and a delete after the change keeps it deleted. |
| WIN-9 | Answered | Every answer is kept. | Every answer from both sides is kept once. |
| WIN-10 | Progress and Review | Worked out again from the answers. | For every question whose answers, Review clear or sitting's delete mark the combine changed, progress and Review are worked out again from all the answers, by the rebuild both sides have. No progress row is removed: one left with no answer that counts stays as it was, the server's where both have one. |
| WIN-11 | Cleared from Review | The clear is kept. | The later clear is kept. A later answer decides again, so a later wrong answer puts the question back (`apps/api/src/progress/service.ts:836`). |
| WIN-12 | A sitting or exam finished | It stays finished. | It never becomes unfinished, whatever the times say: `finishedAt`, `score` and `endReason` come from the finished copy. Finished on both: WIN-1. |
| WIN-13 | Two exams open (running or in their grace) | An open exam stays open. | The one started later stays open. The other ends as `left`, as starting a new exam ends it (`apps/api/src/exams/service.ts:465`, `LocalBank/ExamRoutes.swift:110`). |
| WIN-14 | A name would be taken twice | - | A change that would give two live rows of the result one name (a rename, a move to another list or semester, or a delete undone under WIN-8) is not applied. The row keeps the name, place and delete mark it has in the server's bank, and the result screen says a name was kept. |
| WIN-15 | A row of the result differs from the server's | - | It carries a time of last change later than the server row's: the phone row's own time where that is later, else the later of the combine's clock and one millisecond after the server's time. A question's time is its set's. The server writes a row both hold only when the sent row changed later, so without this it would refuse the bank or keep its own row. |

### The checks before a switch

Two different banks cannot have equal counts, so a combine passes these in place of a move's comparison. The record changes only when all of them hold.

| Check | What it proves | How |
|---|---|---|
| A. Everything is there | Every row of both banks is in the result | For each of the twelve tables, a query looks for a row of either bank that is missing from the result, by its key, through the pairs that were joined. It must find none. |
| B. The numbers add up | Nothing was counted twice or dropped | For each table, rows in the result = rows in the server's bank + rows in the phone's bank - rows that were the same, counted by query inside the same transaction. |
| C. Progress agrees with the answers | Progress and Review are right | The stored progress of every question that gained an answer equals what the engine's rebuild gives from the answers. |
| D. The server agrees (combine up only) | Cloud holds the result | Before it commits, the server checks that every row it held is still there and that each table holds what it held plus what was added. It answers its counts, and the phone compares all twelve with the result. |

Together with how the combine is written, this is why nothing is lost: it only inserts rows and writes the changeable fields of rows both banks hold, with no delete; the phone's own file is only read; the server's route has no delete and refuses an archive that lacks a row it holds; and the app never deletes the server's copy.

### What the combine does not do

- **It works on whole rows.** If one side renamed a folder and the other moved it, the later change wins and the other is dropped. Keeping both would need a time for each field, the next step if real use shows it matters. For the same reason a move of a set's current version after the other side replaced it makes the moved version the one that changed later, and so the current one (WIN-6).
- **A row made later counts as changed later.** Where two rows are joined by name (WIN-2), one a new phone has just made can win over an older change on the server to the same fields, such as a topic's order or its archive mark.
- **It does not bring a folder, course or topic back for what is new inside it.** A set or folder one side added inside one the other side deleted is kept, and hidden with it. Undo brings both back while its 30 days last.
- **It does not take progress away.** After a past exam's delete joins the other bank, a question answered only in that exam keeps the progress row the other bank held (WIN-10).
- **It trusts each device's clock.** A phone whose clock is wrong can win or lose a name, an order or a delete mark it should not. It cannot make an item or an answer disappear.
- **A combine up sends the whole bank**, under the upload's 64 MB limit. A larger one is refused, and nothing switches.

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

It decides two things workers will meet: what the privacy policy says (I-43), and which row of the hand-over table a returning subscriber lands in. With the copy kept, they land in "the server already has a bank", and the phone combines up. With the copy deleted, they land in "no bank on the server" and the phone's bank is uploaded whole. The combine works either way.

## Rules every pull request in this work carries

- Server changes are additive: a new route or field is safe; removing, renaming or narrowing one is not.
- The invited accounts' path is not edited to make room for the new one. New code sits beside it.
- The imported sets, folder names and progress of the accounts that exist today are never deleted, moved or renamed by any change.
- This repository holds no backend source, no `.sql` file, no folder named `migrations`, `deploy` or `infra`, no credentials and no third-party code (`test/release-checks.sh:1047`), and at most 1,000 code lines a file.
- Tests never use a real account, real credentials or the production server: the fake server and scripted fakes, through the Debug launch seam only ([testing.md](testing.md)).
