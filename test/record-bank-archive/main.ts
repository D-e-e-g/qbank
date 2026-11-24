// Records one bank archive v1 from the real server: a synthetic store account fills a bank through
// the API as the app does, and GET /api/me/bank answers the document.
//
// test/record-bank-archive.sh copies this directory to apps/api/scripts in a scratch checkout and
// runs it with that package's tsx. The imports are the server's own source and the contract
// recorder's world helper; they do not resolve from the iPhone repository. The server runs over an
// in-memory database with invented accounts and questions only. Ids are rewritten to fixed
// synthetic ones in the order the server first sent them, so a re-record changes only what the
// server changed.

import { writeFileSync } from "node:fs";
import { finding, plain, source } from "../record-contract/content";
import { STUDENT, World, expect, type Json } from "../record-contract/world";

const [commit, outFile] = process.argv.slice(2);
if (commit === undefined || outFile === undefined || !/^[0-9a-f]{40}$/.test(commit)) throw new Error("usage: main.ts <full-commit> <output.json>");

const world = await World.boot("bank-archive", 30);
await world.account(STUDENT, "synthetic-session-token");
// A store account with Cloud: the server answers every bank route for it.
await world.client.query("update \"user\" set origin = 'store'");
await world.client.query(
  `insert into cloud_entitlement (id, user_id, original_transaction_id, product_id, environment, expires_at, created_at, updated_at)
   select $1, id, $2, 'cloud.monthly', 'sandbox', now() + interval '30 days', now(), now() from "user"`,
  [crypto.randomUUID(), crypto.randomUUID()],
);

const terms = { "invented-term": ["Invented term", "An invented meaning."] } as Record<string, Json>;
const file = (title: string, prefix: string, extra: Record<string, Json> = {}) => source(title, [finding(`${prefix}1`, "Invented topic"), finding(`${prefix}2`, "Invented topic")], { terms, ...extra });
const imported = (json: Record<string, Json>, status = 201) => world.ok("/api/imports", status, { method: "POST", json });

// A row in every table: a course with a semester, a replaced set (two versions), an exam set, a
// page, a topic, answers, an exam left early, a cleared Review, deleted rows, and a place.
const first = await imported({ source: file("Set A", "A"), folderName: "Week 1", newCourse: { code: "INV 101", title: "Invented", semesterNumber: 1 } });
const courseId = first.str("courseId");
const week1 = first.str("folderId");
await imported({ source: file("Set A", "A", { desc: "A replaced set." }), courseId, folderId: week1, decision: "replace" });
const setB = (await imported({ source: file("Set B", "B"), courseId, folderId: week1 })).str("setId");
const week2 = (await imported({ source: source("Set C", [plain("C1", "Invented topic"), plain("C2", "Invented topic")]), courseId, folderName: "Week 2" })).str("folderId");
await imported({ source: source("Set C exam", [plain("C1", "Invented topic", "exam", "C1"), plain("C2", "Invented topic", "exam", "C2")], { kind: "exam" }), courseId, folderId: week2 });
await world.ok(`/api/courses/${courseId}/course-exams`, 201, { method: "POST", json: { name: "Exam 1", folderIds: [week2], badge: "concept" } });
const topic = await world.ok("/api/topics", 201, { method: "POST", json: { title: "Invented topic" } });
await imported({ source: file("Topic set", "T"), courseId: topic.str("id") });

const set = await world.ok(`/api/practice-sets/${setB}`, 200);
for (const [index, question] of set.list("questions").slice(0, 2).entries()) {
  await world.ok("/api/attempts", 201, { method: "POST", json: { clientAttemptId: world.clientId(), questionId: question.str("id"), response: { type: "single", choice: index }, guessed: false } });
}
const exam = await world.ok(`/api/courses/${courseId}/exams`, 201, { method: "POST", json: { folderIds: [week1], pool: "all" } });
await world.ok("/api/attempts", 201, { method: "POST", json: { clientAttemptId: world.clientId(), questionId: exam.list("questions")[0]?.str("id"), response: { type: "single", choice: 1 }, guessed: true, studySessionId: exam.str("id") } });
await world.ok(`/api/exams/${exam.str("id")}/finish`, 200, { method: "POST", json: { reason: "left" } });
await world.ok(`/api/courses/${courseId}/review/clear`, 200, { method: "POST", json: { confirmed: true } });

async function deleted(path: string): Promise<void> {
  const preview = await world.ok(`${path}/delete-preview`, 200);
  await world.ok(path, 204, { method: "DELETE", query: { confirm: preview.str("confirm") } });
}
const goneSet = (await imported({ source: file("Set gone", "G"), courseId, folderId: week1 })).str("setId");
await deleted(`/api/practice-sets/${goneSet}`);
const page = await world.ok(`/api/courses/${courseId}/course-exams`, 201, { method: "POST", json: { name: "Page gone" } });
await world.ok(`/api/course-exams/${page.str("id")}`, 204, { method: "DELETE" });
await deleted(`/api/exams/${exam.str("id")}`);
const goneTopic = await world.ok("/api/topics", 201, { method: "POST", json: { title: "Deleted topic" } });
await imported({ source: file("Deleted topic set", "D"), courseId: goneTopic.str("id") });
await deleted(`/api/courses/${goneTopic.str("id")}`);
await world.ok("/api/me/place", 200, { method: "PUT", json: { courseId } });

await world.record("bank-archive", "/api/me/bank", 200);
const recorded = world.fixtures(commit).get("bank-archive");
expect(recorded !== undefined && typeof recorded === "object" && !Array.isArray(recorded), "the archive was not recorded");
const response = (recorded as Record<string, Json>).response as Record<string, Json>;
writeFileSync(outFile, `${JSON.stringify(response.body, null, 2)}\n`);
await world.close();
console.log(`recorded a bank archive at ${commit}`);
