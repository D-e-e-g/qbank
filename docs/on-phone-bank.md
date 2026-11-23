# The question bank on the phone

The design record for the bank that lives on the iPhone or iPad: how the screens reach it, what it stores, and the one file format that carries a whole bank between the phone and the server. [cloud.md](cloud.md) is its other half: who has which bank, and the rules for moving one.

This is a record to build to, not a description of shipped code. Only the store (I-11, `Packages/QBankKit/Sources/QBankKit/Store`) exists so far, and nothing in the app uses it yet. Statements about today's code name the file and line; they were read at app commit `45ec726` and server commit `b913bcc` (`D-e-e-g/qbank-server`, whose paths start with `apps/` or `packages/`). The contract this repository pins is older, server commit `6acfbcf` (`Packages/QBankKit/Tests/QBankKitTests/Fixtures/pin.json`).

Ids such as A1, I-11 and S-09 name calls and pull requests in the App Store release plan. The maintainers keep that plan outside this repository, and a worker's brief says where.

## Words

- **Bank**: one person's semesters, courses, topics, pages, folders, sets, questions, terms, answers, progress, Review list and exams.
- **Free mode**: a store account with no Cloud. The bank is on the phone and the phone is its authority ([cloud.md](cloud.md)).
- **Server mode**: an invited account, or a store account with Cloud. The bank is on the server, as today.
- **Local engine**: the code that answers the server's contract from the phone's store.

## The seam

### Today

Every screen reaches the server through one struct, `QBankClient`, which sends each request through the `HTTPTransport` it was given (`Packages/QBankKit/Sources/QBankKit/Client/QBankClient.swift:10-23`, and `HTTPTransport.swift:8-10` beside it). The real transport is `URLSessionTransport`. The UI tests already put another one in its place: `FakeQBankServer`, an in-process `HTTPTransport` with invented data (`QBank/Debug/FakeQBankServer.swift:10`).

### Free mode (A1, option T)

In free mode the bank's requests are answered on the phone, in process, by a local engine that is an `HTTPTransport`. It routes the same paths and answers the same JSON, status codes, error codes and sentences as the server, from the store below. `QBankClient`, the models in `QBankKit` and the screens' calls stay as they are.

The account still lives on the server in every mode ([cloud.md](cloud.md)), so in free mode one routing transport sits behind `QBankClient` and picks by path:

| Requests | Paths | Free mode goes to |
|---|---|---|
| The bank | `/api/semesters`, `/api/courses`, `/api/topics`, `/api/topic-order`, `/api/course-exams`, `/api/folders`, `/api/practice-sets`, `/api/imports`, `/api/attempts`, `/api/exams`, `/api/deleted-courses`, `/api/me/place`, with everything under them | The local engine |
| The account | `/health`, `/api/sign-in`, `/api/sign-out`, `/api/session`, `DELETE /api/me`, `/api/me/palette`, and the Cloud routes the server adds | The network, as today |
| Off for store accounts | `/api/question-maker`, `/api/question-jobs`, `/api/twin-jobs`, `/api/agent-keys`, `/api/agent-pairings`, `/api/admin`, `/api/account/password`, `/api/sign-up` | Nowhere: the app does not call them ([cloud.md](cloud.md)) |

The engine serves the bank routes the app calls. Two bank routes of the contract have no caller in the app today, `GET /api/me/export` and `GET /api/me/standing`, and wait until something needs them.

In server mode there is no routing transport and no local engine: `QBankClient` holds the network transport, with the offline cache and the answer queue exactly as today. That is what keeps the invited accounts' path untouched: it is the same code, not a branch inside new code.

### Rules for the local engine

1. **It answers the pinned contract.** The shapes are `openapi.json` and the behavior is the 244 recorded exchanges in `contract/`, both in the `Fixtures` folder that holds the pin. Where the server puts a rule's result or a sentence into an answer (the feedback banner, exam marks, the exam plan, delete warnings), the engine produces the same result and the same words.
2. **It is package code.** The engine, the store and the ported rules live in `Packages/QBankKit` and are proven by `test/package-tests.sh` on the Mac host with no simulator. Scoring is already there (`Packages/QBankKit/Sources/QBankKit/Scoring/Scoring.swift:3-4`). The Debug fake's partial ports of the exam plan and the import check (`QBank/Debug/ExamPlan.swift`, `QBank/Debug/FakeImportCheck.swift`) are replaced by the real ones, and the fake then uses them.
3. **It is written from the contract and the recordings.** No backend source enters this repository. A rule the recordings do not show is recorded first (I-10), then ported.
4. **The clock is handed in.** Exams end by time, Undo lasts 30 days, and answers carry `serverNow` (`Packages/QBankKit/Sources/QBankKit/Models/Exam.swift:295-297`). The engine reads one injected clock for all of it, so tests set the time.
5. **Ids are handed in too.** Every id the engine makes is a lowercase UUID, from an injected generator, so a replay can compare answers with recordings whose ids were rewritten in first-seen order (`test/record-contract/world.ts:1-8`). Swift's `UUID().uuidString` is uppercase: lowercase it.
6. **It does not check the bearer token.** A file on the phone is already the signed-in person's. `QBankClient` still refuses an authenticated call when no session is stored, before any transport is asked (`QBankClient.swift:716-721`), so the bank cannot open without a stored session of some kind. I-30 has to respect that when it opens the bank before the server has answered.
7. **A path it does not serve is a 404 in the contract's error shape** (`error`, `message`; read by `QBankClient.failure`, `QBankClient.swift:741-748`), so a stray call fails loudly in tests.
8. **`importedByAgent` is always null**, since no agent key reaches a bank on the phone.

### What free mode changes outside the transport

Two parts of the app assume the bank is on the server. I-20 handles both without editing the server-mode path:

- **The offline store.** `AppModel` opens an `OfflineStore` (saved copies and the answer queue) for every signed-in account (`QBank/AppModel.swift:243-254`). Free mode opens none; `load` and `submit` then call straight through (`AppModel.swift:193-205`).
- **Screens that wait for a connection.** Import, Add, Exam setup, Recently deleted and parts of the course screen are disabled without a network path (`QBank/Add/ImportModel.swift:56-66`, `QBank/Add/AddView.swift:128`, `QBank/Exam/ExamSetupModel.swift:75-77`, `QBank/Delete/RecentlyDeletedModel.swift:27`, `QBank/Delete/DeletedCoursesModel.swift:25`, `QBank/Course/CourseModel.swift:60`). In free mode the bank is always reachable, so what those screens read must say online whatever the network does. `Connection` already starts online and changes only when a `NetworkWatcher` tells it (`QBank/Offline/Connection.swift:13`, `:25-31`).

The release plan says the screens do not change. The calls do not; the two points above do.

### Proving it matches the server

`test/record-contract.sh` also writes each scenario as an ordered transcript, and `TranscriptReplay` (QBankKit's test support, described in the package README) replays a transcript against any `HTTPTransport` and compares each answer. The engine passes when every bank transcript replays equal. Only times and delete `confirm` tokens are volatile; ids are compared as recorded. After a server change, a re-record shows the drift. Three stored values are in no API answer (`contentHash`, `fileHash`, `stats`), so transcripts cannot prove them; a recorded bank archive can, and I-13 and I-17 use one.

## The store

### Where it is

SQLite through the system library, with no third-party code (A2). One file holds one person's bank.

- **It is the only copy** of a free user's bank, so it is kept in the device's own backup, with file protection on (A12). The saved copies of server mode are the opposite: left out of backups because the server has it all (`Packages/QBankKit/Sources/QBankKit/Offline/ContentCache.swift:72`).
- **Sign-out must not remove it.** Today sign-out erases `Accounts/<account id>/` under `Application Support/QBankKit` (`QBank/Offline/PhoneStorage.swift:40-42`, called from `AppModel.swift:183-190`). The bank and its safety copies live in a folder of their own that sign-out never touches, for example `Application Support/QBankKit/Banks/<key>/`. Only Delete account erases it (I-32).
- **The key is known without the server.** I-30 opens the bank when the server cannot be reached after Apple says yes, and the account id comes from the server (`Packages/QBankKit/Sources/QBankKit/Models/Account.swift`). Apple's user identifier is known at every Sign in with Apple; the server's account id is not. The store itself takes any folder-safe key (I-11).
- **Schema steps are Swift source.** They are numbered, as the server's are, and live in `Store/Schema`, a folder whose name is not `migrations`: `test/release-checks.sh:1047` refuses that name and any `.sql` file.

### How values are stored

| Kind | In SQLite | Form |
|---|---|---|
| id | `TEXT` | A lowercase UUID, `8-4-4-4-12` |
| time | `TEXT` | UTC with milliseconds, exactly `YYYY-MM-DDTHH:MM:SS.sssZ`, the form the API sends (`Packages/QBankKit/Sources/QBankKit/Client/QBankJSON.swift:4`). Fixed width, so text order is time order. |
| date | `TEXT` | `YYYY-MM-DD` |
| bool | `INTEGER` | 0 or 1 |
| int | `INTEGER` | |
| text | `TEXT` | |
| json | `TEXT` | One JSON value. Question bodies are read with the existing `QBankKit` models. |

### Tables

The tables mirror the server's (`apps/api/src/db/schema.ts`): the same table names, the same column names, the same nullability, the same references, with foreign keys on. So moving a bank is a row copy. Three server columns are left out because one file is one person's bank: `owner_id` (semester, course), `user_id` (study_session, attempt, question_progress, review_clear, study_place) and `practice_set.imported_by`.

A column's name is the field's name below in snake case (`sortOrder` is `sort_order`). A `?` marks a field that may be null. Tables marked *deletable* also carry `deletedAt` (time?) and `deletionId` (id?), both null or both set: one delete marks every row it hides with one id, and Undo clears exactly those (`schema.ts:129-137`).

| Table (archive key) | Fields | Server |
|---|---|---|
| `semester` (`semesters`) | `id`, `number` (int, 1 to 3, unique), `name`, `startsOn` (date?), `endsOn` (date?), `archivedAt` (time?), `createdAt` (time) | `schema.ts:140-153` |
| `course` (`courses`), deletable | `id`, `semesterId` (id?, a semester), `kind` (`course` or `topic`), `code` (empty for a topic), `title`, `sortOrder` (int), `archivedAt` (time?), `createdAt` (time). A course has a semester; a topic has none. | `schema.ts:163-179` |
| `course_exam` (`courseExams`), deletable | `id`, `courseId` (a course), `name`, `sortOrder` (int), `linkUrl` (text?), `badge` (`exam`, `concept`, `study` or null), `createdAt` (time). This is a page. | `schema.ts:263-280` |
| `folder` (`folders`), deletable | `id`, `courseId` (a course), `name`, `courseExamId` (id?, a page), `sortOrder` (int), `createdAt` (time) | `schema.ts:309-326` |
| `practice_set` (`practiceSets`), deletable | `id`, `courseId` (a course), `lineageId` (id), `title`, `description`, `weekLabel`, `folderId` (id?, a folder), `sortOrder` (int), `importedAt` (time), `fileHash`, `stats` (json object), `isCurrent` (bool), `replacedAt` (time?), `kind` (`practice` or `exam`) | `schema.ts:181-211` |
| `question` (`questions`) | `id`, `setId` (a set), `lineageId` (id), `publicId`, `position` (int, from 1), `type`, `topic`, `cj` (text?), `clientNeed` (text?), `difficulty` (int?), `weekLabel`, `stem`, `ask`, `body` (json object), `rationale`, `takeaway`, `termKeys` (json list of text), `source` (text?), `contentHash`, `twinOf` (text?), `twinOfLineageId` (id?) | `schema.ts:213-246` |
| `term` (`terms`) | `id`, `setId` (a set), `key`, `term`, `meaning` | `schema.ts:248-256` |
| `study_session` (`studySessions`), deletable | `id`, `courseId` (a course), `mode` (`practice`, `exam` or `review`), `setId` (id?, a set), `questionIds` (json list of text), `examWeeks` (json list?), `examFolderIds` (json list?), `timeLimitSeconds` (int?), `startedAt` (time), `finishedAt` (time?), `score` (json object?), `endReason` (`finished`, `left`, `timeout` or null), `examPool` (`all` or `wrong`), `examPracticeWeeks` (json list?), `seededQuestionIds` (json list?) | `schema.ts:329-362` |
| `attempt` (`attempts`) | `id`, `clientAttemptId` (id, unique), `studySessionId` (id?, a study session), `questionId` (a question), `response` (json), `shuffle` (json?), `status` (`correct`, `partial` or `incorrect`), `points` (int), `maxPoints` (int), `guessed` (bool), `answeredAt` (time) | `schema.ts:368-389` |
| `question_progress` (`questionProgress`) | `questionLineageId` (id, the key), `attempts` (int), `correctAttempts` (int), `lastStatus`, `lastGuessed` (bool), `lastAnsweredAt` (time), `lastPoints` (int), `lastMaxPoints` (int), `inReview` (bool), `lastAttemptId` (an attempt) | `schema.ts:395-418` |
| `review_clear` (`reviewClears`) | `questionLineageId` (id, the key), `lastAttemptId` (an attempt), `clearedAt` (time) | `schema.ts:424-437` |
| `study_place` (`studyPlace`) | `courseId` (a course), `updatedAt` (time). At most one row. | `schema.ts:440-448` |

Notes for I-11:

- A folder's name is unique within its list, counting each delete apart: the server's constraint is `unique nulls not distinct (course_id, course_exam_id, name, deletion_id)` (`apps/api/src/db/deletion-migration.ts:19`). SQLite treats nulls as distinct, so the phone needs a unique index over expressions that fold null to a fixed value.
- A topic's title is unique ignoring case among topics that are not deleted (`deletion-migration.ts:35`).
- As built, beyond the table: the tables are `STRICT`, and each column carries a `CHECK` that its text has its kind's exact form (lowercase UUID, the API's time and date forms, `0` or `1`, JSON of the stated shape), that an enum column holds one of the listed values, that a deletable row's two marks are both null or both set, and that a course has a semester exactly when its kind is `course`. `folder.course_exam_id` is `ON DELETE SET NULL`, as on the server. `study_place` holds at most one row through a unique index over a constant. The server defers its folder-name rule to the end of a transaction so two folders can swap names; SQLite checks a unique index at each statement, so the engine swaps through a temporary name. SQLite's `lower()` folds ASCII only, so the topic-title index is a floor and the engine checks the full rule.
- The file is `Banks/<key>/bank.sqlite` with the default rollback journal, so it is one file with no side files left at rest. The file and its folder are set to `completeUntilFirstUserAuthentication` and to be kept in the backup every time the store opens. The schema version is SQLite's `user_version`; a file from a newer step than the app knows is refused and left alone. Each step runs with foreign keys off, as SQLite's table rebuild needs, and commits only when `foreign_key_check` finds no broken reference. A transaction that SQLite rolls back on its own (a full disk, an I/O error) runs no further statement and fails its commit, so nothing of it is kept.
- Stored rows are as written, not as read. An exam whose time ran out keeps a null `finishedAt` until something ends it; the engine works out its end at the read, as the server does.

### What is not on the phone

| Server tables | Why not |
|---|---|
| `user`, `session`, `account`, `verification`, `passkey`, `password_lockout`, `sign_up_email`, `admin_student` | The account lives on the server in every mode |
| `question_job`, `question_job_material`, `question_maker_calibration` | Make questions and exam twins are off for store accounts |
| `agent_key`, `agent_pairing`, `agent_import`, `agent_deletion` | Connect an agent is off for store accounts |
| `course_exam_week` | Legacy: read once to place folders on pages and no longer written (`schema.ts:282-301`) |

## Bank archive v1

One document that holds a whole bank. It is what moves between the phone and Cloud in both directions (S-09, I-17), and it is the file Settings > Export shares (I-25). It is a row copy of the twelve tables above, so nothing is recomputed on the way.

It is a new format beside the server's progress export (`nclex-qbank-progress`, `apps/api/src/progress/export.ts:13`), which holds no question bodies and stays as it is.

### The document

One JSON object, UTF-8, with these keys:

| Key | Value |
|---|---|
| `format` | The text `qbank-bank-archive` |
| `version` | The integer `1` |
| `exportedAt` | A time: when it was written |
| `writtenBy` | `phone` or `server` |
| `complete` | A bool: false when the writer had to leave a row out (see Closed, below) |
| `counts` | An object with the twelve table keys, each an integer |
| `semesters`, `courses`, `courseExams`, `folders`, `practiceSets`, `questions`, `terms`, `studySessions`, `attempts`, `questionProgress`, `reviewClears` | Each a list of rows |
| `studyPlace` | One row, or null |

```json
{
  "format": "qbank-bank-archive",
  "version": 1,
  "exportedAt": "2026-11-22T14:37:05.123Z",
  "writtenBy": "phone",
  "complete": true,
  "counts": { "semesters": 0, "courses": 1, "courseExams": 0, "folders": 1, "practiceSets": 1, "questions": 2, "terms": 0, "studySessions": 0, "attempts": 1, "questionProgress": 1, "reviewClears": 0, "studyPlace": 1 },
  "semesters": [],
  "courses": [{ "id": "0b0e6a52-7c1d-4f0e-9a43-1f2d3c4b5a69", "semesterId": null, "kind": "topic", "code": "", "title": "Geography", "sortOrder": 1, "archivedAt": null, "createdAt": "2026-11-20T09:00:00.000Z", "deletedAt": null, "deletionId": null }],
  "studyPlace": { "courseId": "0b0e6a52-7c1d-4f0e-9a43-1f2d3c4b5a69", "updatedAt": "2026-11-22T14:30:00.000Z" }
}
```

(The other lists are left out of the example. A real document has every key.)

### Rows and fields

1. A row is an object with **every field of its table** from the table above, under the field's name as written there, plus `deletedAt` and `deletionId` on a deletable table. A field that may be null is written as `null`, never left out.
2. A value has the form of its kind: an id is a lowercase UUID, a time is `YYYY-MM-DDTHH:MM:SS.sssZ`, a date is `YYYY-MM-DD`, a bool is `true` or `false`, an int is a JSON integer. The server stores some times with more digits; it writes them cut to milliseconds, as its API already does (`iso`, `apps/api/src/progress/service.ts:1027-1031`).
3. A json field is the JSON value itself, not text holding JSON, and is carried unchanged. Order inside a list is data and is kept. Images ride inside a question's `body` as data URLs of up to 300 KB each (`packages/questions/src/media.ts:28-31`), so an archive can be large.
4. **Ids are kept.** Every id and lineage id is the same on both sides of a move. Neither side renumbers.
5. **Deleted rows are in it**, with their marks, so Undo still works after a move for whatever is left of its 30 days (`apps/api/src/content/delete-marks.ts:16`). Every version of a set is in it, not only the current one.
6. The owner columns the phone leaves out are not in a row. The server fills them with the signed-in account when it stores one.

### Closed

Every reference in a row names a row in the same document. The references are the ones the tables say: `semesterId`, `courseId`, `courseExamId`, `folderId`, `setId`, `studySessionId`, `questionId`, `lastAttemptId`, and the course of `studyPlace`. Lineage ids, `deletionId`, `twinOf`, `twinOfLineageId` and the ids inside json lists are plain values and are not checked.

A phone's store has foreign keys on, so it is always closed. The server can hold a few rows that are not: an answer to a question in another account's course, from before content was private to each account (`apps/api/src/progress/export.ts:281-285`, `apps/api/src/content/access.ts:97-99`). The server leaves such a row out, then any row that referred to it, until the document is closed, and writes `"complete": false`. A store account was made after that time, so its archive is always complete. A move between phone and Cloud takes only a complete archive.

### Order

Readers never depend on order. Writers produce it so that two archives of one bank can be compared by eye and a reader can store rows as it reads them:

1. Keys in the order of the table above: the header keys, then the tables in the order listed, which puts every row after the rows it refers to. `studyPlace` is last.
2. Rows by `id` ascending as text; `questionProgress` and `reviewClears` by `questionLineageId`. For lowercase UUIDs this is also the server's own order for the column.

### Counts, and how they are compared

`counts[key]` is the number of rows in that table of the bank, deleted rows and old versions included. `studyPlace` is 1 or 0. No other number is compared: no sums and no hashes.

Three comparisons, and every one must hold on all twelve keys. A missing key is a difference.

1. **The document against itself.** The reader counts the rows in each list and compares with `counts`. This catches a cut-off or hand-edited file.
2. **What was stored against the document.** After writing, inside the same transaction, the reader counts the rows it now holds, by query, and compares with `counts`. A difference rolls the whole write back.
3. **The other side's answer against the sender's own store.** After an upload the server answers `{ "counts": { ... } }` from the query in step 2. The phone compares that with counts it queries from its own store, which has not changed since the archive was written ([cloud.md](cloud.md), the lease). For a download the phone is the reader, so steps 1 and 2 are the comparison.

Only after the comparisons hold does the authority change ([cloud.md](cloud.md)).

### What a reader checks

A reader stores an archive whole or not at all, in one transaction. It refuses the document, and stores nothing, unless all of this holds:

1. It is one JSON object, `format` is `qbank-bank-archive`, and `version` is a version the reader implements.
2. Every key of the document is present, and `counts` passes comparison 1.
3. Every row has every field with a value of the field's kind. A field the reader does not know is ignored.
4. Keys are unique within a table, and `clientAttemptId` is unique among attempts.
5. The document is closed, a deletable row's two marks are both null or both set, and a course has a semester exactly when its kind is `course`.
6. Comparison 2 holds.

The server, on an upload, also requires (S-09):

7. `complete` is true, and the account has no bank: none of the twelve tables holds a row of the account, deleted rows included.
8. No id in the document is already on the server, in any account.
9. Each set passes the import check, the same one `POST /api/imports` runs. The set is rebuilt as a question file from its rows: `title`, `desc` from `description`, `kind`, a `terms` object of `key: [term, meaning]`, and its questions in `position` order, each the `body` object plus the hoisted fields under their file names (`id` from `publicId`, `type`, `topic`, `cj`, `need` from `clientNeed`, `diff` from `difficulty`, `wk` from `weekLabel`, `stem`, `ask`, `rationale`, `takeaway`, `terms` from `termKeys`, `src` from `source`), leaving out a null or empty one (`packages/questions/src/import.ts:30-44`, `apps/api/src/content/import-set.ts:208-235`). A set with an error refuses the whole archive. The server stores the question and term fields the check returns and takes everything else from the rows (ids, lineage ids, positions, times, order, folder, version marks), except `contentHash` and `stats`, which it works out itself (`apps/api/src/content/hash.ts:9-26`, `import-set.ts:348-365`). For a set made by the same rules the result is the rows that were sent.

The phone does not run the import check on an archive from the server. A person whose Cloud ended must get their bank back even if a rule was tightened after a set was imported.

### Versions

`version` goes up when a field is removed or renamed, or when what a field means changes. A new field does not change it, and a reader ignores a field it does not know. That makes a new field safe only if losing it on a round trip through an older app is harmless; a field that must survive needs version 2.

A reader refuses a version it does not implement. Apps in the field cannot be changed after they ship, so `GET /api/me/bank` answers version 1 for as long as an app that reads only version 1 is supported, and a later version is asked for by name.

## Rules that keep the two sides the same

- **The import rules are one set.** The phone applies the server's import check, with the A11 changes (S-10, I-13), or a set made on the phone could be refused when it moves to Cloud.
- **`contentHash` must be byte for byte the server's.** On a replace, a question keeps its lineage, and so its answers, only when its hash is unchanged (`import-set.ts:206-216`). The phone has to produce the same hash for the same question, or the first replace after a move would cut every answer loose. It is the SHA-256 of a sorted-key text of twelve fields (`hash.ts:9-41`).
- **A changed server rule is re-recorded** before the phone is changed (rule 7 of the plan's worker rules).
