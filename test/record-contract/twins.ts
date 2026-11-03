// Exam twins of the questions she got wrong in a folder, written by the server's own fake model:
// one followed from its first step to the exam on its twins, one cancelled, one the model fails,
// every refusal, and the daily limit they share with Make questions.

import { ModelError } from "@nclex-qbank/question-maker";
import { examSetOf, practiceSet } from "@nclex-qbank/question-maker/testing";
import { FakeModel, json, lastSet, never, promptOf } from "../../src/question-maker/fake-model";
import { QuestionRunner } from "../../src/question-maker/runner";
import { STUDENT, World, expect } from "./world";

const OTHER = { email: "other.student@example.com", password: "synthetic-other-pass", name: "Other Student", role: "student" as const };

export async function recordTwins(): Promise<World[]> {
  const fake = new FakeModel();
  let made: QuestionRunner | undefined;
  const world = await World.boot(21, {
    questionMaker: (db) => {
      made = new QuestionRunner({ db, client: fake, sweepMs: 0, log: () => undefined });
      return { settings: { accounts: [STUDENT.email], dailyLimit: 3 }, runner: made };
    },
  });
  const runner = (): QuestionRunner => {
    if (made === undefined) throw new Error("the question maker was not set up");
    return made;
  };
  await world.account(STUDENT, "synthetic-session-token");
  const other = await world.account(OTHER, "synthetic-other-session-token");

  // Week 5 holds two sets, Week 6 one; each question's topic names its set, so its twin says which it twins.
  const semesterId = (await world.ok("/api/semesters", 201, { method: "POST", json: { number: 3 } })).str("id");
  const courseId = (await world.ok("/api/courses", 201, { method: "POST", json: { semesterId, code: "NURS 406", title: "Invented Mental Health" } })).str("id");
  const setIn = async (folderName: string, title: string, size: number, prefix: string) => {
    const set = practiceSet(size, title, 1, prefix);
    set.questions.forEach((question, index) => {
      question.topic = `${title.split(" ").slice(-2).join(" ")} ${String(index + 1)}`;
    });
    return world.ok("/api/imports", 201, { method: "POST", json: { source: JSON.stringify({ ...set, desc: "Invented." }), courseId, folderName } });
  };
  const harderA = await setIn("Week 5", "Week 5 Harder A", 4, "A");
  const harderB = await setIn("Week 5", "Week 5 Harder B", 2, "B");
  const firstPass = await setIn("Week 6", "Week 6 First Pass", 3, "C");
  const week5 = harderA.str("folderId");
  const week6 = firstPass.str("folderId");
  world.name(courseId, "c0000000-0000-4000-8000-000000000501");
  world.name(week5, "f0000000-0000-4000-8000-000000000501");
  world.name(week6, "f0000000-0000-4000-8000-000000000502");
  world.name(harderA.str("setId"), "5e700000-0000-4000-8000-000000000501");
  world.name(harderB.str("setId"), "5e700000-0000-4000-8000-000000000502");
  world.name(firstPass.str("setId"), "5e700000-0000-4000-8000-000000000503");

  const wrong = async (set: typeof harderA, publicId: string) => {
    const questionId = (await world.ok(`/api/practice-sets/${set.str("setId")}`, 200)).find("questions", "publicId", publicId).str("id");
    await world.ok("/api/attempts", 201, { method: "POST", json: { clientAttemptId: world.clientId(), questionId, response: { type: "single", choice: 1 }, guessed: false } });
  };
  await wrong(harderA, "A01");
  await wrong(harderA, "A03");
  await wrong(harderB, "B02");

  await world.record("twin-jobs-not-allowed", "/api/twin-jobs", 403, { token: other });
  const twins = (folderId: string, pool: "wrong" | "all") => ({ method: "POST", json: { courseId, folderIds: [folderId], pool } });
  await world.record("twin-job-no-wrong", "/api/twin-jobs", 400, twins(week6, "wrong"));

  // Twins of her three wrong questions, held after the first set's twins so she sees two of three written.
  let release: () => void = () => undefined;
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  let twinCalls = 0;
  fake.on("twins", async (request) => {
    twinCalls += 1;
    if (twinCalls === 2) await held;
    return json(examSetOf(lastSet(promptOf(request))));
  });
  const job = (await world.record("twin-job-start", "/api/twin-jobs", 202, twins(week5, "wrong"))).str("id");
  world.name(job, "a0b00000-0000-4000-8000-000000000501");
  await fake.started("twins", 2);
  await world.record("twin-job-twins", `/api/twin-jobs/${job}`, 200);
  release();
  await runner().idle();
  fake.off("twins");
  const done = await world.record("twin-job-done", `/api/twin-jobs/${job}`, 200);
  expect(done.str("status") === "done", "the twins were not filed", done.value);
  const [twinsA, twinsB] = done.list("sets");
  expect(twinsA !== undefined && twinsB !== undefined, "the twins were not filed beside both sets", done.value);
  world.name(twinsA.str("setId"), "5e700000-0000-4000-8000-000000000504");
  world.name(twinsB.str("setId"), "5e700000-0000-4000-8000-000000000505");
  const exam = await world.record("twin-exam-start", `/api/courses/${courseId}/exams`, 201, { method: "POST", json: { folderIds: [week5], pool: "wrong" } });
  world.name(exam.str("id"), "e0000000-0000-4000-8000-000000000501");
  await world.ok(`/api/exams/${exam.str("id")}/finish`, 200, { method: "POST", json: { reason: "finished" } });
  await world.record("twin-job-cancel-finished", `/api/twin-jobs/${job}/cancel`, 409, { method: "POST" });
  await world.record("twin-job-already-twinned", "/api/twin-jobs", 400, twins(week5, "wrong"));

  // Twins of all of Week 6, cancelled while QBank still reads its questions.
  const mapped = fake.count("source-map");
  fake.on("source-map", never);
  const stopped = (await world.ok("/api/twin-jobs", 202, twins(week6, "all"))).str("id");
  world.name(stopped, "a0b00000-0000-4000-8000-000000000502");
  await fake.started("source-map", mapped + 1);
  await world.record("twin-job-cancel", `/api/twin-jobs/${stopped}/cancel`, 200, { method: "POST" });
  await runner().idle();
  fake.off("source-map");

  // One more wrong question in Week 5, and a model that does not answer.
  await wrong(harderA, "A04");
  fake.on("twins", () => {
    throw new ModelError("The model did not answer.", "unavailable");
  });
  const failed = (await world.ok("/api/twin-jobs", 202, twins(week5, "wrong"))).str("id");
  world.name(failed, "a0b00000-0000-4000-8000-000000000503");
  await runner().idle();
  fake.off("twins");
  await world.record("twin-job-failed", `/api/twin-jobs/${failed}`, 200);

  await world.record("twin-jobs", "/api/twin-jobs", 200);
  await world.record("twin-job-daily-limit", "/api/twin-jobs", 429, twins(week6, "all"));
  await world.record("question-maker-twins-daily-limit", "/api/question-maker", 200);
  await world.record("twin-job-not-found", "/api/twin-jobs/0e000000-0000-4000-8000-000000000501", 404);
  await runner().stop();
  await world.close();
  return [world];
}
