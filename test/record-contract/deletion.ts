// Deleting and Undo: a set, a folder with its sets, a past exam, a course or study topic, and an
// exam page, each previewed first, with Recently deleted. Past the 30-day window is reached the way
// the server's own tests reach it: the row's deleted_at is moved 31 days back.

import { finding, source } from "./content";
import { STUDENT, World, expect, type CallInit, type Doc, type Json } from "./world";

export async function recordDeletion(): Promise<World[]> {
  return [await contents(), await courses(), await pages()];
}

const SHIFT = "deleted_at = deleted_at - interval '31 days'";

/** A course with a semester, its folders made by importing sets into them. */
async function course(world: World, number: number, code: string, title: string): Promise<{ semesterId: string; courseId: string }> {
  const semesterId = (await world.ok("/api/semesters", 201, { method: "POST", json: { number } })).str("id");
  const courseId = (await world.ok("/api/courses", 201, { method: "POST", json: { semesterId, code, title } })).str("id");
  return { semesterId, courseId };
}

async function importSet(world: World, courseId: string, folderName: string, title: string, count: number, kind: "practice" | "exam" = "practice"): Promise<Doc> {
  const prefix = kind === "exam" ? "E" : "Q";
  const questions = Array.from({ length: count }, (_, index) => finding(`${prefix}${String(index + 1)}`, `${title} topic ${String(index + 1)}`));
  const extra: Record<string, Json> = kind === "exam" ? { desc: "Invented set.", kind } : { desc: "Invented set." };
  return world.ok("/api/imports", 201, { method: "POST", json: { source: source(title, questions, extra), courseId, folderName, decision: "import" } });
}

/** Answers question `index` of a set, right or wrong, in practice or on an exam. */
async function answer(world: World, set: Doc | string, index: number, right: boolean, examId?: string): Promise<void> {
  const questionId = typeof set === "string" ? set : (await world.ok(`/api/practice-sets/${set.str("setId")}`, 200)).list("questions")[index]?.str("id");
  expect(questionId !== undefined, "no question to answer");
  await world.ok("/api/attempts", 201, {
    method: "POST",
    json: { clientAttemptId: world.clientId(), questionId, response: { type: "single", choice: right ? 0 : 1 }, guessed: false, ...(examId === undefined ? {} : { studySessionId: examId }) },
  });
}

const confirmed = (confirm: string): CallInit => ({ method: "DELETE", query: { confirm } });

/** A course's sets, a folder with its sets, and a past exam: deleted, refused, listed, and brought back. */
async function contents(): Promise<World> {
  const world = await World.boot(15);
  await world.account(STUDENT, "synthetic-session-token");
  const { semesterId, courseId } = await course(world, 1, "NURS 210", "Invented Heart and Lungs");
  const heartA = await importSet(world, courseId, "Week 1", "Heart A", 4);
  const heartB = await importSet(world, courseId, "Week 1", "Heart B", 3);
  const heartExam = await importSet(world, courseId, "Week 1", "Heart A exam", 3, "exam");
  const lungs = await importSet(world, courseId, "Week 2", "Lungs", 3);
  const kidneys = await importSet(world, courseId, "Week 2", "Kidneys", 1);
  const week1 = heartA.str("folderId");
  const week2 = lungs.str("folderId");
  const exam1 = (await world.ok(`/api/courses/${courseId}/course-exams`, 201, { method: "POST", json: { name: "Exam 1", folderIds: [week1] } })).str("id");

  // In Week 1 she answered three of Heart A, one wrong, and one of Heart B, wrong; in Week 2, Lungs 1 right and Lungs 3 wrong.
  await answer(world, heartA, 0, true);
  await answer(world, heartA, 1, true);
  await answer(world, heartA, 2, false);
  await answer(world, heartB, 0, false);
  await answer(world, lungs, 0, true);
  await answer(world, lungs, 2, false);

  // Kidneys went more than 30 days ago.
  const kidneysPreview = await world.ok(`/api/practice-sets/${kidneys.str("setId")}/delete-preview`, 200);
  await world.ok(`/api/practice-sets/${kidneys.str("setId")}`, 204, confirmed(kidneysPreview.str("confirm")));
  await world.sql(`update practice_set set ${SHIFT} where deleted_at is not null and course_id = $1`, [courseId]);

  // A past exam over Week 2: Lungs 1 again and Lungs 2, both right; Lungs 3 unanswered.
  const pastExam = (await world.ok(`/api/courses/${courseId}/exams`, 201, { method: "POST", json: { folderIds: [week2], pool: "all" } })).str("id");
  const lungsSet = await world.ok(`/api/practice-sets/${lungs.str("setId")}`, 200);
  const lungsQuestion = (publicId: string) => lungsSet.find("questions", "publicId", publicId).str("id");
  await answer(world, lungsQuestion("Q1"), 0, true, pastExam);
  await answer(world, lungsQuestion("Q2"), 0, true, pastExam);
  await world.ok(`/api/exams/${pastExam}/finish`, 200, { method: "POST", json: { reason: "finished" } });

  // A set: its preview, a confirm that no longer matches, the delete, and Undo.
  const set = (id: string) => `/api/practice-sets/${id}`;
  const preview = await world.record("practice-set-delete-preview", `${set(heartB.str("setId"))}/delete-preview`, 200);
  await world.record("practice-set-delete-preview-exam", `${set(heartExam.str("setId"))}/delete-preview`, 200);
  await world.record("practice-set-delete-changed", set(heartB.str("setId")), 409, confirmed("0000000000000000"));
  await world.record("practice-set-delete", set(heartB.str("setId")), 204, confirmed(preview.str("confirm")));
  await world.record("practice-set-undo-delete", `${set(heartB.str("setId"))}/undo-delete`, 200, { method: "POST" });

  // A folder: refused without confirm, and refused again when a set lands in it after the warning.
  const folder = `/api/folders/${week1}`;
  await world.record("folder-delete-unconfirmed", folder, 409, { method: "DELETE" });
  const folderPreview = await world.record("folder-delete-preview", `${folder}/delete-preview`, 200);
  const heartC = await importSet(world, courseId, "Week 1", "Heart C", 2);
  await world.record("folder-delete-changed", folder, 409, confirmed(folderPreview.str("confirm")));
  const again = await world.record("folder-delete-preview-changed", `${folder}/delete-preview`, 200);
  await world.record("folder-delete", folder, 204, confirmed(again.str("confirm")));
  await world.record("practice-set-undo-with-folder", `${set(heartA.str("setId"))}/undo-delete`, 409, { method: "POST" });

  // The past exam, then Lungs on its own.
  const exam = `/api/exams/${pastExam}`;
  const examPreview = await world.record("exam-delete-preview", `${exam}/delete-preview`, 200);
  await world.record("exam-delete", exam, 204, confirmed(examPreview.str("confirm")));
  const lungsPreview = await world.ok(`${set(lungs.str("setId"))}/delete-preview`, 200);
  await world.ok(set(lungs.str("setId")), 204, confirmed(lungsPreview.str("confirm")));
  await world.record("course-deleted", `/api/courses/${courseId}/deleted`, 200);
  await world.record("exam-undo-delete", `${exam}/undo-delete`, 200, { method: "POST" });
  await world.record("folder-undo-delete", `${folder}/undo-delete`, 200, { method: "POST" });
  await world.record("practice-set-undo-expired", `${set(kidneys.str("setId"))}/undo-delete`, 409, { method: "POST" });

  // An exam still going over Week 1 asks Heart A exam's questions.
  const running = (await world.ok(`/api/courses/${courseId}/exams`, 201, { method: "POST", json: { folderIds: [week1], pool: "all" } })).str("id");
  const inUse = await world.record("practice-set-delete-preview-in-use", `${set(heartExam.str("setId"))}/delete-preview`, 200);
  expect(!inUse.isNull("refusal"), "a set a running exam asks was not refused", inUse.value);
  await world.record("practice-set-delete-in-use", set(heartExam.str("setId")), 409, confirmed(inUse.str("confirm")));
  const runningPreview = await world.record("exam-delete-preview-in-progress", `/api/exams/${running}/delete-preview`, 200);
  await world.record("exam-delete-in-progress", `/api/exams/${running}`, 409, confirmed(runningPreview.str("confirm")));

  world.name(semesterId, "5e000000-0000-4000-8000-000000000701");
  world.name(courseId, "c0000000-0000-4000-8000-000000000701");
  world.name(week1, "f0000000-0000-4000-8000-000000000701");
  world.name(week2, "f0000000-0000-4000-8000-000000000702");
  world.name(exam1, "ce000000-0000-4000-8000-000000000701");
  [heartA, heartB, heartExam, lungs, kidneys, heartC].forEach((imported, index) => {
    world.name(imported.str("setId"), `5e700000-0000-4000-8000-00000000070${String(index + 1)}`);
  });
  world.name(pastExam, "e0000000-0000-4000-8000-000000000701");
  world.name(running, "e0000000-0000-4000-8000-000000000702");
  await world.close();
  return world;
}

/** A course with an exam going, then deleted; a study topic deleted after it; Home's Recently deleted, and Undo. */
async function courses(): Promise<World> {
  const world = await World.boot(16);
  await world.account(STUDENT, "synthetic-session-token");
  const { semesterId, courseId } = await course(world, 2, "NURS 220", "Fundamentals");
  const basics = await importSet(world, courseId, "Week 1", "Fundamentals A", 3);
  await importSet(world, courseId, "Week 1", "Fundamentals B", 2);
  await answer(world, basics, 0, false);
  const coursePath = `/api/courses/${courseId}`;

  const examId = (await world.ok(`${coursePath}/exams`, 201, { method: "POST", json: { folderIds: [basics.str("folderId")], pool: "all" } })).str("id");
  const inUse = await world.record("course-delete-preview-in-use", `${coursePath}/delete-preview`, 200);
  await world.record("course-delete-in-use", coursePath, 409, confirmed(inUse.str("confirm")));
  await world.ok(`/api/exams/${examId}/finish`, 200, { method: "POST", json: { reason: "finished" } });
  const preview = await world.record("course-delete-preview", `${coursePath}/delete-preview`, 200);
  await world.record("course-delete", coursePath, 204, confirmed(preview.str("confirm")));
  // Another course takes its code meanwhile.
  await world.ok("/api/courses", 201, { method: "POST", json: { semesterId, code: "NURS 220", title: "Fundamentals again" } });

  const topicId = (await world.ok("/api/topics", 201, { method: "POST", json: { title: "Pharmacology" } })).str("id");
  await importSet(world, topicId, "Week 1", "Pharmacology A", 3);
  const topic = `/api/courses/${topicId}`;
  const topicPreview = await world.record("topic-delete-preview", `${topic}/delete-preview`, 200);
  await world.ok(topic, 204, confirmed(topicPreview.str("confirm")));
  await world.record("deleted-courses", "/api/deleted-courses", 200);
  await world.record("course-undo-delete", `${topic}/undo-delete`, 200, { method: "POST" });
  await world.record("course-undo-delete-code-taken", `${coursePath}/undo-delete`, 409, { method: "POST" });

  world.name(semesterId, "a0000000-0000-4000-8000-000000000802");
  world.name(courseId, "c0000000-0000-4000-8000-000000000801");
  world.name(topicId, "c0000000-0000-4000-8000-000000000802");
  await world.close();
  return world;
}

/** Exam pages: one deleted while its folders stay in the course, refusals, Recently deleted, and Undo. */
async function pages(): Promise<World> {
  const world = await World.boot(17);
  await world.account(STUDENT, "synthetic-session-token");
  const { semesterId, courseId } = await course(world, 1, "NURS 101", "Foundations");
  const heart = await importSet(world, courseId, "Week 1", "Heart A", 3);
  const lungs = await importSet(world, courseId, "Week 3", "Lungs A", 2);
  const kidneys = await importSet(world, courseId, "Week 4", "Kidneys A", 3);
  await importSet(world, courseId, "Week 4", "Kidneys A exam", 2, "exam");
  const skin = await importSet(world, courseId, "Week 5", "Skin A", 2);
  const mixed = await importSet(world, courseId, "First Pass", "Mixed A", 2);
  const [week1, week3, week4, week5] = [heart, lungs, kidneys, skin].map((set) => set.str("folderId")) as [string, string, string, string];
  const pagesPath = `/api/courses/${courseId}/course-exams`;
  const exam1 = (await world.ok(pagesPath, 201, { method: "POST", json: { name: "Exam 1", folderIds: [week1] } })).str("id");
  const exam2 = (await world.ok(pagesPath, 201, { method: "POST", json: { name: "Exam 2", folderIds: [week3, week4] } })).str("id");
  await answer(world, lungs, 0, true);
  const pastExam = (await world.ok(`/api/courses/${courseId}/exams`, 201, { method: "POST", json: { folderIds: [week3, week4], pool: "all" } })).str("id");
  await world.ok(`/api/exams/${pastExam}/finish`, 200, { method: "POST", json: { reason: "finished" } });

  const page = (id: string) => `/api/course-exams/${id}`;
  const preview = await world.record("course-exam-delete-preview", `${page(exam2)}/delete-preview`, 200);
  await world.record("course-exam-delete-unconfirmed", page(exam2), 409, { method: "DELETE" });
  // Week 5 goes on the page after she was warned.
  await world.ok(`/api/folders/${week5}`, 200, { method: "PATCH", json: { examPageId: exam2 } });
  await world.record("course-exam-delete-changed", page(exam2), 409, confirmed(preview.str("confirm")));
  const again = await world.record("course-exam-delete-preview-changed", `${page(exam2)}/delete-preview`, 200);
  await world.record("course-exam-delete", page(exam2), 204, confirmed(again.str("confirm")));
  await world.record("course-exam-delete-gone", `${page(exam2)}/delete-preview`, 404);
  await world.record("course-after-exam-page-delete", `/api/courses/${courseId}`, 200);
  await world.record("course-deleted-exam-page", `/api/courses/${courseId}/deleted`, 200);
  await world.record("course-exam-undo-delete", `${page(exam2)}/undo-delete`, 200, { method: "POST" });

  // Deleted again, and another page takes its name: its folder has the name of one in the Folders list.
  const second = await world.ok(`${page(exam2)}/delete-preview`, 200);
  await world.ok(page(exam2), 204, confirmed(second.str("confirm")));
  const draft = (await world.ok(`/api/courses/${courseId}/folders`, 201, { method: "POST", json: { name: "Draft" } })).str("id");
  const newExam2 = (await world.ok(pagesPath, 201, { method: "POST", json: { name: "Exam 2", folderIds: [draft] } })).str("id");
  await world.ok(`/api/folders/${draft}`, 200, { method: "PATCH", json: { name: "First Pass" } });
  await world.record("course-deleted-exam-page-name-taken", `/api/courses/${courseId}/deleted`, 200);
  await world.record("course-exam-undo-delete-name-taken", `${page(exam2)}/undo-delete`, 409, { method: "POST" });
  const taken = await world.record("course-exam-delete-preview-name-taken", `${page(newExam2)}/delete-preview`, 200);
  await world.record("course-exam-delete-name-taken", page(newExam2), 409, confirmed(taken.str("confirm")));

  // Exam 1 went more than 30 days ago.
  const exam1Preview = await world.ok(`${page(exam1)}/delete-preview`, 200);
  await world.ok(page(exam1), 204, confirmed(exam1Preview.str("confirm")));
  await world.sql(`update course_exam set ${SHIFT} where id = $1`, [exam1]);
  await world.record("course-exam-undo-expired", `${page(exam1)}/undo-delete`, 409, { method: "POST" });

  world.name(semesterId, "a0000000-0000-4000-8000-000000000901");
  world.name(courseId, "c0000000-0000-4000-8000-000000000901");
  world.name(exam1, "ce000000-0000-4000-8000-000000000901");
  world.name(exam2, "ce000000-0000-4000-8000-000000000902");
  world.name(newExam2, "ce000000-0000-4000-8000-000000000903");
  world.name(week1, "f0000000-0000-4000-8000-000000000901");
  world.name(week3, "f0000000-0000-4000-8000-000000000902");
  world.name(week4, "f0000000-0000-4000-8000-000000000903");
  world.name(week5, "f0000000-0000-4000-8000-000000000904");
  world.name(mixed.str("folderId"), "f0000000-0000-4000-8000-000000000905");
  world.name(draft, "f0000000-0000-4000-8000-000000000906");
  [heart, lungs, kidneys, skin, mixed].forEach((set, index) => {
    world.name(set.str("setId"), `5e700000-0000-4000-8000-00000000090${String(index + 1)}`);
  });
  world.name(pastExam, "e0000000-0000-4000-8000-000000000901");
  await world.close();
  return world;
}
