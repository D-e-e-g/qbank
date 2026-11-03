// Make questions, driven by the server's own fake model (src/question-maker/fake-model.ts), so no
// call leaves the machine: a set from her notes through her check of the samples to the filed set
// and its exam twins, a set from a file, copies of a quiz from her photos, a cancelled set, the
// daily limit, and the accounts and servers it is not open to.

import { practiceSet, twinOf } from "@nclex-qbank/question-maker/testing";
import { FakeModel, json, never } from "../../src/question-maker/fake-model";
import { QuestionRunner } from "../../src/question-maker/runner";
import { STUDENT, World, expect, type Doc, type Json } from "./world";

const NOTES = "Invented lecture notes for week 4.\nSlide 1: invented topics for a test.";
/** "# Invented week 5 notes\n\n- Invented topic for a test.\n" as a Markdown file. */
const MARKDOWN = "IyBJbnZlbnRlZCB3ZWVrIDUgbm90ZXMKCi0gSW52ZW50ZWQgdG9waWMgZm9yIGEgdGVzdC4K";
/** The smallest JPEG: a start and an end marker. */
const JPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2Q==";

export async function recordMakeQuestions(): Promise<World[]> {
  return [await making(), await notAllowed(), await notSetUp()];
}

/** Boots a world whose question maker runs on `fake`, open to `accounts`. */
async function boot(scenario: number, fake: FakeModel, accounts: string[]): Promise<{ world: World; runner: () => QuestionRunner }> {
  let made: QuestionRunner | undefined;
  const world = await World.boot(scenario, {
    questionMaker: (db) => {
      made = new QuestionRunner({ db, client: fake, sweepMs: 0, log: () => undefined });
      return { settings: { accounts, dailyLimit: 4 }, runner: made };
    },
  });
  return {
    world,
    runner: () => {
      if (made === undefined) throw new Error("the question maker was not set up");
      return made;
    },
  };
}

async function making(): Promise<World> {
  const fake = new FakeModel();
  const { world, runner } = await boot(18, fake, [STUDENT.email]);
  await world.account(STUDENT, "synthetic-session-token");
  const semesterId = (await world.ok("/api/semesters", 201, { method: "POST", json: { number: 3 } })).str("id");
  const courseId = (await world.ok("/api/courses", 201, { method: "POST", json: { semesterId, code: "NURS 310", title: "Invented Mental Health" } })).str("id");
  const reference = await world.ok("/api/imports", 201, {
    method: "POST",
    json: { source: JSON.stringify({ ...practiceSet(4, "Invented exam review", 1, "R"), desc: "Invented." }), courseId, folderName: "Week 4" },
  });
  const week4 = reference.str("folderId");
  world.name(courseId, "c0000000-0000-4000-8000-000000000401");
  world.name(week4, "f0000000-0000-4000-8000-000000000401");
  world.name(reference.str("setId"), "5e700000-0000-4000-8000-000000000401");

  await world.record("question-maker", "/api/question-maker", 200);
  const job = (path: string) => `/api/question-jobs/${path}`;

  // From her notes: five samples, rewritten once at her note, then the rest, checked and filed with exam twins.
  const notes = await world.record("question-job-start", "/api/question-jobs", 202, {
    method: "POST",
    json: { courseId, folderId: week4, materialKind: "notes", material: { text: NOTES }, level: "exam", referenceSetId: reference.str("setId"), count: 10, examTwins: true },
  });
  const notesId = notes.str("id");
  world.name(notesId, "a0b00000-0000-4000-8000-000000000401");
  await runner().idle();
  const waiting = await world.record("question-job-samples", job(notesId), 200);
  expect(waiting.str("waitingFor") === "samples", "the set is not waiting for her check of the samples", waiting.value);
  await world.record("question-samples", job(`${notesId}/samples`), 200);
  await world.record("question-samples-revise", job(`${notesId}/samples/revise`), 202, {
    method: "POST",
    json: { changes: [{ questionId: "A02", note: "Make it about walking." }] },
  });
  await runner().idle();
  const revised = await world.record("question-samples-revised", job(`${notesId}/samples`), 200);
  expect(revised.num("round") === 2, "the samples were not rewritten", revised.value);
  await world.record("question-result-not-finished", job(`${notesId}/result`), 409);
  await world.record("question-samples-accept", job(`${notesId}/samples/accept`), 202, { method: "POST", json: { words: "Sample 3: Make the stem about day 3." } });
  await runner().idle();
  const done = await world.record("question-job-done", job(notesId), 200);
  expect(done.str("status") === "done", "the set from her notes did not finish", done.value);
  const [practice, exam] = done.list("sets");
  expect(practice !== undefined && exam !== undefined, "the set from her notes filed no exam twins", done.value);
  world.name(practice.str("id"), "5e700000-0000-4000-8000-000000000402");
  world.name(exam.str("id"), "5e700000-0000-4000-8000-000000000403");
  await world.record("question-result", job(`${notesId}/result`), 200);

  // From a file, into a folder it makes: it stops for her check of the samples, and she leaves it there.
  const file = await world.record("question-job-file-start", "/api/question-jobs", 202, {
    method: "POST",
    json: {
      courseId,
      folderName: "Week 5",
      materialKind: "notes",
      material: { file: { name: "Week 5 notes.md", mediaType: "text/markdown", data: MARKDOWN } },
      level: "course",
      count: 12,
      examTwins: false,
    },
  });
  world.name(file.str("id"), "a0b00000-0000-4000-8000-000000000402");
  await runner().idle();

  // A quiz copied from two photos: two questions with their key, one with an answer QBank suggests, a blurry bottom.
  const [one, two, three] = practiceSet(3, "Invented quiz", 1, "P").questions;
  expect(one !== undefined && two !== undefined && three !== undefined, "the quiz has no three questions");
  // P02 is select-all: an exam twin's wording, as a question of the quiz itself.
  const sata = { ...Object.fromEntries(Object.entries(twinOf(two)).filter(([key]) => key !== "twinOf")), id: "P02" };
  fake.on("copy", () =>
    json({
      title: "Invented quiz",
      terms: {},
      questions: [
        { photo: 1, answerFrom: "photo", explanationsFrom: "photo", question: one },
        { photo: 1, answerFrom: "photo", explanationsFrom: "qbank", question: sata },
        { photo: 2, answerFrom: "suggested", explanationsFrom: "qbank", question: three },
      ],
      unreadable: [{ photo: 2, reason: "The bottom of photo 2 is blurry." }],
    }),
  );
  const copy = await world.record("question-job-copy-start", "/api/question-jobs", 202, {
    method: "POST",
    json: { courseId, folderId: week4, materialKind: "questions", material: { images: [{ mediaType: "image/jpeg", data: JPEG }, { mediaType: "image/jpeg", data: JPEG }] }, examTwins: true },
  });
  const copyId = copy.str("id");
  world.name(copyId, "a0b00000-0000-4000-8000-000000000403");
  await runner().idle();
  await world.record("question-job-copies", job(copyId), 200);
  const copies = await world.record("question-copies", job(`${copyId}/copies`), 200);
  const fileOf = (id: string): Doc => copies.find("questions", "id", id).get("file");
  await world.record("question-copies-accept-invalid", job(`${copyId}/copies/accept`), 400, {
    method: "POST",
    json: { keep: [{ id: "P01", question: { ...fileOf("P01").fields(), options: [] } }] },
  });
  // She keeps P01 as copied, and P03 with her own answer, B, in place of the one QBank suggested.
  const herAnswer = fileOf("P03")
    .list("options")
    .map((option, index): Json => {
      const kept = Object.fromEntries(Object.entries(option.fields()).filter(([key]) => key !== "ok"));
      return index === 1 ? { ...kept, ok: true } : kept;
    });
  await world.record("question-copies-accept", job(`${copyId}/copies/accept`), 202, {
    method: "POST",
    json: { keep: [{ id: "P01" }, { id: "P03", question: { ...fileOf("P03").fields(), options: herAnswer } }] },
  });
  await runner().idle();
  fake.off("copy");
  const copied = await world.record("question-result-copies", job(`${copyId}/result`), 200);
  world.name(copied.get("set").str("setId"), "5e700000-0000-4000-8000-000000000404");
  world.name(copied.get("examSet").str("setId"), "5e700000-0000-4000-8000-000000000405");

  // A set she cancels while it is still writing its samples, then cancels again.
  const mapped = fake.count("source-map");
  fake.on("source-map", never);
  const stopped = (await world.ok("/api/question-jobs", 202, { method: "POST", json: { courseId, materialKind: "notes", material: { text: NOTES }, count: 10 } })).str("id");
  world.name(stopped, "a0b00000-0000-4000-8000-000000000404");
  await fake.started("source-map", mapped + 1);
  await world.record("question-job-cancel", job(`${stopped}/cancel`), 200, { method: "POST" });
  await runner().idle();
  fake.off("source-map");
  await world.record("question-job-cancel-finished", job(`${stopped}/cancel`), 409, { method: "POST" });

  await world.record("question-jobs", "/api/question-jobs", 200);
  await world.record("question-job-daily-limit", "/api/question-jobs", 429, {
    method: "POST",
    json: { courseId, materialKind: "notes", material: { text: NOTES }, level: "exam", count: 15, examTwins: true },
  });
  await world.record("question-maker-daily-limit", "/api/question-maker", 200);
  await world.record("question-job-not-found", job("a0b00000-0000-4000-8000-000000000499"), 404);
  await runner().stop();
  await world.close();
  return world;
}

/** A server that makes questions, for other accounts than hers. */
async function notAllowed(): Promise<World> {
  const { world, runner } = await boot(19, new FakeModel(), ["someone.else@example.com"]);
  await world.account(STUDENT, "synthetic-session-token");
  await world.record("question-maker-not-allowed", "/api/question-maker", 200);
  await world.record("question-jobs-not-allowed", "/api/question-jobs", 403);
  await runner().stop();
  await world.close();
  return world;
}

/** A server with no model key: it lists her account but has no runner. */
async function notSetUp(): Promise<World> {
  const world = await World.boot(20, { questionMaker: () => ({ settings: { accounts: [STUDENT.email], dailyLimit: 4 }, runner: null }) });
  await world.account(STUDENT, "synthetic-session-token");
  await world.record("question-maker-not-set-up", "/api/question-maker", 200);
  await world.record("question-jobs-not-set-up", "/api/question-jobs", 503);
  await world.close();
  return world;
}
