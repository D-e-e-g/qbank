// A course as she studies it: its catalog card and page, a set of every format, terms, her answers
// to each, Review, exams over every question and over her wrong ones, her place, and the export.
// Restoring a replaced set is its own world.

import { everyFormat, plain, question, source } from "./content";
import { STUDENT, World, expect, type CallInit, type Json } from "./world";

export async function recordPractice(): Promise<World[]> {
  return [await studying(), await restoring(), await continuing()];
}

async function studying(): Promise<World> {
  const world = await World.boot(10);
  await world.account(STUDENT, "synthetic-session-token");
  await world.record("place-empty", "/api/me/place", 200);
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 101", title: "Invented Nursing Basics" } });
  const courseId = course.str("id");
  const file = async (text: string, folderName: string) =>
    world.ok("/api/imports", 201, { method: "POST", json: { source: text, courseId, folderName, decision: "import" } });
  const basics = await file(
    source("Week 1 - Set 1: Invented basics", everyFormat(), {
      desc: "Invented practice questions, one per format.",
      terms: { tachy: ["Tachycardia", "An invented definition of a fast heart rate."] },
    }),
    "Week 1",
  );
  // Week 1's exam bank: an exam twin of each of the first two questions.
  await file(
    source("Week 1 exam bank", [plain("E1", "Invented exam topic 1", "exam", "Q1"), plain("E2", "Invented exam topic 2", "exam", "Q2")], { kind: "exam", desc: "Invented exam questions." }),
    "Week 1",
  );
  const followUp = await file(
    source("Week 2 - Set 1: Invented follow-up", [plain("R1", "Invented week 2 topic 1"), plain("R2", "Invented week 2 topic 2")], { desc: "Two more invented questions." }),
    "Week 2",
  );

  await world.record("semesters", "/api/semesters", 200);
  const detail = await world.record("course", `/api/courses/${courseId}`, 200);
  const set = await world.record("practice-set", `/api/practice-sets/${basics.str("setId")}`, 200);
  await world.record("terms", `/api/courses/${courseId}/terms`, 200);
  const week1 = detail.find("folders", "name", "Week 1").str("id");
  const week2 = detail.find("folders", "name", "Week 2").str("id");
  const id = (publicId: string) => set.find("questions", "publicId", publicId).str("id");

  // Her answers, one per format.
  const answer = (clientAttemptId: string, publicId: string, response: Json, extra: Record<string, Json> = {}): CallInit => ({
    method: "POST",
    json: { clientAttemptId, questionId: id(publicId), response, guessed: false, ...extra },
  });
  const saved = answer("11111111-1111-4111-8111-111111111111", "Q1", { type: "single", choice: 1 }, { shuffle: { kind: "options", order: [2, 0, 1] } });
  await world.record("attempt-saved", "/api/attempts", 201, saved);
  await world.record("attempt-partial", "/api/attempts", 201, answer("44444444-4444-4444-8444-444444444444", "Q3", { type: "sata", picks: [0, 2] }, { shuffle: { kind: "options", order: [3, 2, 1, 0] } }));
  await world.record(
    "attempt-guessed",
    "/api/attempts",
    201,
    answer("55555555-5555-4555-8555-555555555555", "Q2", { type: "priority", choice: 0 }, { guessed: true, shuffle: { kind: "options", order: [1, 2, 0] } }),
  );
  await world.record("attempt-highlight", "/api/attempts", 201, answer("66666666-6666-4666-8666-000000000000", "Q4", { type: "highlight", picks: [1, 2] }, { shuffle: { kind: "plain" } }));
  await world.record("attempt-order", "/api/attempts", 201, answer("66666666-6666-4666-8666-000000000001", "Q5", { type: "order", positions: [0, 2, 1] }, { shuffle: { kind: "order", start: [2, 1, 0] } }));
  await world.record(
    "attempt-match",
    "/api/attempts",
    201,
    answer("66666666-6666-4666-8666-000000000002", "Q6", { type: "match", choices: ["Class A", null] }, { shuffle: { kind: "match", choices: ["Class C", "Class A", "Class B"] } }),
  );
  await world.record("attempt-matrix", "/api/attempts", 201, answer("66666666-6666-4666-8666-000000000003", "Q7", { type: "matrix", choices: ["Indicated", "Indicated"] }, { shuffle: { kind: "plain" } }));
  await world.record(
    "attempt-cloze",
    "/api/attempts",
    201,
    answer("66666666-6666-4666-8666-000000000004", "Q8", { type: "cloze", choices: [1, null] }, { shuffle: { kind: "cloze", blanks: [[2, 0, 1], [1, 0]] } }),
  );
  const replayed = await world.record("attempt-replayed", "/api/attempts", 200, saved);
  expect(replayed.get("replayed").value === true, "a repeated attempt id was not replayed", replayed.value);
  await world.record("attempt-conflict", "/api/attempts", 409, answer("11111111-1111-4111-8111-111111111111", "Q1", { type: "single", choice: 0 }));
  await world.record("attempt-invalid", "/api/attempts", 400, answer("22222222-2222-4222-8222-222222222222", "Q1", { type: "sata", picks: [0] }));
  await world.record("attempt-signed-out", "/api/attempts", 401, { ...answer("33333333-3333-4333-8333-333333333333", "Q1", { type: "single", choice: 0 }), token: null });

  const review = `/api/courses/${courseId}/review`;
  await world.record("review", review, 200);
  await world.record("review-guessed", review, 200, { query: { filter: "guessed" } });
  await world.record("review-practice", `${review}/practice`, 200, { query: { filter: "missed" } });
  await world.record("review-practice-one", `${review}/practice`, 200, { query: { question: id("Q1") } });

  // An exam over every question, one answered, then finished; then one over her wrong questions.
  const exams = `/api/courses/${courseId}/exams`;
  await world.record("exam-setup", exams, 200);
  await world.record("exam-start-no-wrong", exams, 400, { method: "POST", json: { folderIds: [week2], pool: "wrong" } });
  const exam = await world.record("exam-start", exams, 201, { method: "POST", json: { folderIds: [week1, week2], pool: "all" } });
  const examId = exam.str("id");
  await world.record("exam-setup-in-progress", exams, 200);
  const examQuestion = (publicId: string) => exam.find("questions", "publicId", publicId).str("id");
  const onExam = (clientAttemptId: string, publicId: string, choice: number, shuffle?: Json): CallInit => ({
    method: "POST",
    json: { clientAttemptId, questionId: examQuestion(publicId), response: { type: "single", choice }, guessed: false, ...(shuffle ? { shuffle } : {}), studySessionId: examId },
  });
  await world.record("exam-attempt", "/api/attempts", 201, onExam("77777777-7777-4777-8777-777777777777", "R1", 0, { kind: "options", order: [0, 2, 1] }));
  await world.record("exam-attempt-again", "/api/attempts", 409, onExam("88888888-8888-4888-8888-888888888888", "R1", 1));
  await world.record("exam-running", `/api/exams/${examId}`, 200);
  await world.record("exam-finish", `/api/exams/${examId}/finish`, 200, { method: "POST", json: { reason: "finished" } });
  await world.record("exam-ended", `/api/exams/${examId}`, 200);
  await world.record("exam-attempt-after-end", "/api/attempts", 409, onExam("99999999-9999-4999-8999-999999999999", "R2", 0));
  const wrong = await world.record("exam-start-wrong", exams, 201, { method: "POST", json: { folderIds: [week1], pool: "wrong" } });
  await world.record("exam-setup-after", exams, 200);

  await world.record("place-put", "/api/me/place", 200, { method: "PUT", json: { courseId } });
  await world.record("place", "/api/me/place", 200);
  await world.record("export", "/api/me/export", 200);
  await world.record("review-clear-unconfirmed", `${review}/clear`, 400, { method: "POST", json: { confirmed: false } });
  await world.record("review-clear", `${review}/clear`, 200, { method: "POST", json: { confirmed: true } });
  await world.record("course-not-found", "/api/courses/00000000-0000-4000-8000-000000000000", 404);

  world.name(semester.str("id"), "5e000000-0000-4000-8000-000000000201");
  world.name(courseId, "c0000000-0000-4000-8000-000000000201");
  world.name(week1, "f0000000-0000-4000-8000-000000000201");
  world.name(week2, "f0000000-0000-4000-8000-000000000202");
  world.name(basics.str("setId"), "5e700000-0000-4000-8000-000000000201");
  world.name(followUp.str("setId"), "5e700000-0000-4000-8000-000000000202");
  world.name(examId, "e0000000-0000-4000-8000-000000000201");
  world.name(wrong.str("id"), "e0000000-0000-4000-8000-000000000202");
  await world.close();
  return world;
}

/** A set replaced by a new file, and its earlier version brought back. */
async function restoring(): Promise<World> {
  const world = await World.boot(11);
  await world.account(STUDENT, "synthetic-session-token");
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 101", title: "Invented Nursing Basics" } });
  const title = "Week 1 - Set 1: Invented basics";
  const earlier = [question("Q1", "An invented client is short of breath."), question("Q2", "An invented client has a racing heart.")];
  const json = (questions: Json[], decision: string): CallInit => ({
    method: "POST",
    json: { source: source(title, questions), courseId: course.str("id"), folderName: "Week 1", decision },
  });
  await world.ok("/api/imports", 201, json(earlier, "import"));
  const replaced = await world.ok("/api/imports", 201, json([...earlier, question("Q3", "An invented client feels lightheaded.")], "replace"));
  expect(replaced.str("kind") === "replaced", "the second file did not replace the set", replaced.value);
  const current = replaced.str("setId");
  const restored = await world.record("practice-set-restore", `/api/practice-sets/${current}/restore`, 200, { method: "POST" });
  expect(restored.str("status") === "restored" && restored.num("questionCount") === 2, "the earlier version did not come back", restored.value);
  await world.record("practice-set-restore-not-current", `/api/practice-sets/${current}/restore`, 404, { method: "POST" });
  await world.close();
  return world;
}

/**
 * A set she left midway. A Review answer leaves a set with an answer and no sitting row, the shape a
 * set she was midway through before sittings has, so its sitting has no id yet. Her next answer saves
 * the sitting, and Start over ends it.
 */
async function continuing(): Promise<World> {
  const world = await World.boot(18);
  await world.account(STUDENT, "synthetic-session-token");
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 101", title: "Invented Nursing Basics" } });
  const courseId = course.str("id");
  const imported = await world.ok("/api/imports", 201, {
    method: "POST",
    json: { source: source("Week 1 - Set 1: Invented basics", [plain("Q1", "Invented topic 1"), plain("Q2", "Invented topic 2"), plain("Q3", "Invented topic 3")]), courseId, folderName: "Week 1", decision: "import" },
  });
  const setId = imported.str("setId");
  const setPath = `/api/practice-sets/${setId}`;
  const set = await world.ok(setPath, 200);
  const id = (publicId: string) => set.find("questions", "publicId", publicId).str("id");
  const answer = (clientAttemptId: string, publicId: string, extra: Record<string, Json> = {}): CallInit => ({
    method: "POST",
    json: { clientAttemptId, questionId: id(publicId), response: { type: "single", choice: 0 }, guessed: false, shuffle: { kind: "options", order: [1, 0, 2] }, ...extra },
  });

  await world.record("attempt-from-review", "/api/attempts", 201, answer("aaaaaaaa-1111-4111-8111-111111111111", "Q1", { fromReview: true }));
  const dayOne = await world.record("practice-set-sitting-day-one", setPath, 200);
  expect(dayOne.get("sitting").get("id").value === null, "a set with answers and no sitting row read as saved", dayOne.value);
  await world.record("course-sitting-day-one", `/api/courses/${courseId}`, 200);

  await world.record("attempt-opens-sitting", "/api/attempts", 201, answer("bbbbbbbb-2222-4222-8222-222222222222", "Q2"));
  const midway = await world.record("practice-set-sitting", setPath, 200);
  expect(midway.get("sitting").get("id").value !== null, "her answer did not save the sitting", midway.value);
  await world.record("course-sitting", `/api/courses/${courseId}`, 200);

  const ended = await world.record("practice-set-start-over", `${setPath}/start-over`, 200, { method: "POST" });
  expect(ended.get("ended").value === true, "Start over ended nothing", ended.value);
  const again = await world.record("practice-set-start-over-nothing", `${setPath}/start-over`, 200, { method: "POST" });
  expect(again.get("ended").value === false, "a second Start over ended something", again.value);
  await world.record("practice-set-start-over-not-found", "/api/practice-sets/00000000-0000-4000-8000-000000000000/start-over", 404, { method: "POST" });
  await world.record("practice-set-after-start-over", setPath, 200);
  await world.record("course-after-start-over", `/api/courses/${courseId}`, 200);

  world.name(semester.str("id"), "5e000000-0000-4000-8000-000000000301");
  world.name(courseId, "c0000000-0000-4000-8000-000000000301");
  world.name(setId, "5e700000-0000-4000-8000-000000000301");
  await world.close();
  return world;
}
