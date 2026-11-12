# QBankKit

The app's connection to the QBank server, with no UI: the API client, the session store, and the offline core. The app target and its screens build on it.

## What is in it

- **`QBankClient`** - the endpoints the app's screens use: sign-up for an email the owner added (`signUp`), password sign-in, session check, sign-out, signing out of every device at once (`signOutEverywhere`), which forgets the session here only once the server has ended them all, and password change; deleting the signed-in user account for good with its password (`deleteAccount`), which forgets the session here; semesters, courses with their pages, folders, sets and exams, terms, practice sets with her sitting (`PracticeSet.sitting`, the question she left off at) and her standing in the set (`SetRun`: new, midway, restarted or done, as the server sends it), ending that sitting (`startPracticeSetOver`), and restoring a replaced set; adding, renaming and removing a course's pages ("Exam 1" and the folders on it) and setting or clearing a page's badge (`PageBadge`: Exam, Concept or Study); making and renaming folders, putting a folder on a page, saving her folder order, and moving sets between folders; adding, renaming, moving, and archiving semesters and courses from Settings; answers (`recordAttempt`, keyed by `clientAttemptID`, and marked `fromReview` from the Review runner); Review and its runner; exam setup with per-folder wrong counts, start (`pool` `.all` or `.wrong`), read, and finish; study place, the account's color scheme (`setPalette`, Dusk or Slate, on `Account.palette`), and progress export; Connect an agent for Settings: the agent waiting under the code she types (`agentPairing(code:)`), her answer (`approveAgentPairing`, `denyAgentPairing`), her agent keys (`agentKeys`), and revoking one (`revokeAgentKey`), never a key itself, with a set's `importedByAgent` naming the key that imported it; checking and importing a question file (`checkImport`, `importSet`, with its replace question); making questions on the accounts the server allows (`questionMakerStatus`, `questionJobs`, `startQuestionJob`, the samples and copies she checks, the result, and cancel); exam twins of the folders and pool she ticks on Exam setup (`twinJobs`, `startTwinJob`, `twinJob`, `cancelTwinJob`, and `startExam(courseID:on:)`, which sends a finished job's exam as the server wrote it); and deleting a course or study topic with everything in it, a set, a folder with every set in it, or a past exam, each in three steps: its preview (`courseDeletion`, `practiceSetDeletion`, `folderDeletion`, `examDeletion`) with the warning in the server's words and a `confirm`, the delete that sends that `confirm` (`deleteCourse`, `deletePracticeSet`, `deleteFolder`, `deleteExam`), and Undo for 30 days (`undoDeleteCourse`, `undoDeletePracticeSet`, `undoDeleteFolder`, `undoDeleteExam`), with `recentlyDeletedCourses` and a course's `recentlyDeleted` listing what Undo can still bring back. Calls are `async throws(QBankError)`. Sign-in stores the bearer token through a `SessionStore`, and every later call sends it as `Authorization: Bearer`. The client keeps no cookies. The only server fact here is the public address in `APIConfiguration.production`; there is no API key.
- **`SessionStore`** - `KeychainSessionStore` keeps the token, its expiry, and the account as one Keychain item under `<bundle id>.session` (this device only, readable after first unlock). `InMemorySessionStore` is for tests and previews.
- **`AttemptQueue`** - every answer is saved on the phone first, then sent oldest first. An answer made without signal waits and goes out when the connection is back. The server saves each `clientAttemptID` once and answers a repeat with the saved attempt, so a send whose reply was lost is simply sent again. An answer the server refuses (a 4xx such as `exam_finished`) leaves the queue and is reported; one that can succeed later (no signal, 5xx, 429, signed out, a temporary password) waits. `FilePendingAttemptStore` keeps the queue in `Application Support/QBankKit`.
- **`ContentCache`** - loaded semesters, courses, practice sets, terms, and Review lists, keyed by `CacheKey` and stamped with when they were saved. `FileContentCache` keeps one JSON file per value in `Application Support/QBankKit/Content`, out of backups.
- **`WaitingProgress`** - answers still waiting on the phone, counted into a set's and a course's answered and fully right counts, so a set practiced without signal shows her answers before they are sent. It never counts high: where the phone cannot know whether a question was answered before, it counts at least the waiting answers. They count in a set's sitting too, on its row and in `PracticeSet.counting(waiting:)`, so a night without signal opens at the right question.
- **`Scoring`** - the server's scoring rules and its feedback wording (Correct, Partly correct, the points line and the scoring rule), so an answer waiting to be sent shows the same mark the server records later; once saved, the app shows the server's own words (`SavedAttempt.pointsText` and `ruleText`, `ExamResult.Item.label`). The contract tests check it against the server's own marks for every format.
- **Models** - `Codable` types matching the server's responses. A question's format-specific `body` is read into `QuestionBody`, and kept as sent in `rawBody`, so tables, images, and fields added later survive the offline cache. A question format this version does not know decodes as `.unsupported` instead of failing the whole set. A course row carries a `kind`, `.course` or `.topic` (a study topic: no semester, an empty code), open so a kind added later still decodes; `CourseDetail.semester` is nil for a topic, and anything from before topics reads as a course.

## Tests

```sh
swift test --package-path Packages/QBankKit
```

`test/package-tests.sh` runs this on macOS in `xcode.yml`. On the iOS Simulator:

```sh
cd Packages/QBankKit
../../test/sim.sh -- xcodebuild test -scheme QBankKit \
  -destination 'platform=iOS Simulator,id={{UDID}}'
```

Nothing in a test run reaches the network: the client talks through `HTTPTransport`, and tests answer with recorded responses. The Keychain tests write real items under a throwaway service on macOS; a package test bundle on the iOS Simulator has no Keychain entitlement, so they skip there, and they skip wherever the login keychain is locked (a CI runner service with its own security session).

### Contract fixtures

`Tests/QBankKitTests/Fixtures/contract/` holds one exchange per file: the request the app sends and the response the server gave. Every file is a live recording from the server commit in `Fixtures/pin.json` and carries that commit as `recordedFrom`; a test requires it of every file. They hold no real student data and no real credentials.

`test/record-contract.sh` records them from a checkout of the pinned server. It copies the checkout to a scratch tree, adds the scenarios in `test/record-contract/`, and runs them there in-process: the server's own app over a throwaway in-memory database, with invented accounts and invented course content, and nothing over the network. Make questions and exam twins run on the server's own fake model (`apps/api/src/question-maker/fake-model.ts`), so no model is called. The end of the 30-day Undo window is reached the way the server's own tests reach it: the deleted row's `deleted_at` is moved 31 days back. The recorder fails when a scenario's call answers a status it did not expect, or when a fixture in the directory has no scenario.

A recording keeps what the server sent, rewritten only so that a re-record changes what the server changed and nothing else:

- Every id the server made becomes a fixed synthetic one: the id a test names where it names one, numbered in the order the server first sent it otherwise.
- Session tokens and agent keys become `synthetic-*` placeholders, user ids become `synthetic-user-N`, and agent pairing codes become fixed stand-ins.
- Times and delete `confirm` tokens stay as the server sent them, so tests read them from the recording instead of naming them.

`Tests/QBankKitTests/Fixtures/openapi.json` is a copy of the server's OpenAPI document (`apps/api/openapi.json` in the server repository, served at `https://qbank.dimitrygallego.com/openapi.json`). `Fixtures/pin.json` names the server commit that copy and every fixture come from. A test checks that every recorded call and status is documented there, that every key in a recorded response is allowed by that schema, and that every key the kit reads while decoding a recording (watched through a recording `Decoder`) is a property of it.

When the server's API changes, re-record from a checkout of the commit to pin. The script reads that checkout and does not fetch:

```sh
test/record-contract.sh /path/to/qbank-server
```

Then run the package tests.

A topic is a course row of kind `topic` with no semester and an empty code. `semesters.json` stays the catalog from before this account had topics, with `topics` present and empty, which is how the server sends that list.
