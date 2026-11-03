// Organizing her courses: semesters and courses from Settings, a course's pages and folders, moving
// sets, her folder order, and importing set files.

import { finding, safetyChecks, source } from "./content";
import { STUDENT, World, expect, type CallInit, type Json } from "./world";

export async function recordOrganizing(): Promise<World[]> {
  return [await catalog(), await folders(), await imports()];
}

async function catalog(): Promise<World> {
  const world = await World.boot(12);
  await world.account(STUDENT, "synthetic-session-token");
  const first = await world.record("semester-create", "/api/semesters", 201, { method: "POST", json: { number: 1 } });
  await world.record("semester-create-taken", "/api/semesters", 409, { method: "POST", json: { number: 1 } });
  await world.record("semester-create-out-of-range", "/api/semesters", 400, { method: "POST", json: { number: 4 } });
  const semester = `/api/semesters/${first.str("id")}`;
  await world.record("semester-update", semester, 200, { method: "PATCH", json: { name: "Fall 2026", startsOn: "2026-09-01", endsOn: null } });
  await world.record("semester-update-blank", semester, 400, { method: "PATCH", json: { name: "  " } });
  const second = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 2 } });
  const basics = await world.record("course-create", "/api/courses", 201, {
    method: "POST",
    json: { semesterId: first.str("id"), code: "NURS 101", title: "Invented Basics" },
  });
  await world.record("course-create-taken", "/api/courses", 409, { method: "POST", json: { semesterId: first.str("id"), code: "nurs 101", title: "Again" } });
  const other = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: first.str("id"), code: "NURS 102", title: "Invented Second" } });
  const course = `/api/courses/${basics.str("id")}`;
  await world.record("course-update", course, 200, {
    method: "PATCH",
    json: { code: "NURS 111", title: "Invented Basics II", semesterId: second.str("id") },
  });
  await world.record("course-update-blank", course, 400, { method: "PATCH", json: { title: "" } });
  await world.record("course-archive", course, 200, { method: "PATCH", json: { archived: true } });
  await world.record("semesters-edited", "/api/semesters", 200);

  world.name(first.str("id"), "5e000000-0000-4000-8000-000000000001");
  world.name(second.str("id"), "5e000000-0000-4000-8000-000000000002");
  world.name(basics.str("id"), "c0000000-0000-4000-8000-000000000101");
  world.name(other.str("id"), "c0000000-0000-4000-8000-000000000102");
  await world.close();
  return world;
}

/** A course's pages and folders, as FolderContractTests names them. */
async function folders(): Promise<World> {
  const world = await World.boot(13);
  await world.account(STUDENT, "synthetic-session-token");
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 101", title: "Invented Nursing Basics" } });
  const courseId = course.str("id");
  const file = async (title: string, week: string, questions: number, desc: string) => {
    const set = Array.from({ length: questions }, (_, index) => finding(`Q${String(index + 1)}`, `week ${week} topic ${String(index + 1)}`));
    return world.ok("/api/imports", 201, { method: "POST", json: { source: source(title, set, { desc }), courseId, folderName: `Week ${week}`, decision: "import" } });
  };
  const set1 = await file("Week 1 - Set 1: Invented week 1", "1", 3, "Invented practice questions for week 1.");
  const set2 = await file("Week 2 - Set 1: Invented week 2", "2", 2, "Invented practice questions for week 2.");
  const set3 = await file("Week 3 - Set 1: Invented week 3", "3", 2, "Invented practice questions for week 3.");
  const mixed = await file("Week 3 - Set 2: Invented mixed review", "3", 2, "Invented practice questions for week 3.");
  const [week1, week2, week3] = [set1.str("folderId"), set2.str("folderId"), set3.str("folderId")];
  const page = (name: Json, folderIds: Json): CallInit => ({ method: "POST", json: { name, folderIds } });
  const pages = `/api/courses/${courseId}/course-exams`;

  await world.record("course-exam-create-blank", pages, 400, page("  ", []));
  const exam1 = (await world.record("course-exam-create", pages, 201, page("Exam 1", [week1, week2]))).str("id");
  await world.record("course-exam-create-folder-taken", pages, 409, page("Exam 2", [week2, week3]));
  await world.record("course-exam-create-name-taken", pages, 409, page("exam 1", [week3]));
  await world.record("course-exam-create-unknown-folder", pages, 400, page("Exam 2", ["f0000000-0000-4000-8000-000000000999"]));
  await world.record("course-exam-update", `/api/course-exams/${exam1}`, 200, { method: "PUT", json: { name: "Midterm", folderIds: [week2, week1] } });
  // Before Exam 2 is made, so the id the app asks for is no page of hers.
  await world.record("course-exam-not-found", "/api/course-exams/ce000000-0000-4000-8000-000000000002/delete-preview", 404);
  const exam2 = (await world.ok(pages, 201, page("Exam 2", [week3]))).str("id");
  await world.record("course-exam-update-folder-taken", `/api/course-exams/${exam2}`, 409, { method: "PUT", json: { name: "Exam 2", folderIds: [week1, week3] } });

  const folders = `/api/courses/${courseId}/folders`;
  await world.record("folder-create-blank", folders, 400, { method: "POST", json: { name: "  " } });
  const firstPass = (await world.record("folder-create", folders, 201, { method: "POST", json: { name: "First Pass" } })).str("id");
  await world.record("folder-create-taken", folders, 409, { method: "POST", json: { name: "first pass" } });
  const folder = `/api/folders/${firstPass}`;
  await world.record("folder-rename", folder, 200, { method: "PATCH", json: { name: "Mixed review" } });
  await world.record("folder-rename-taken", `/api/folders/${week2}`, 409, { method: "PATCH", json: { name: "week 1" } });
  await world.record("folder-not-found", "/api/folders/f0000000-0000-4000-8000-000000000999", 404, { method: "PATCH", json: { name: "Anything" } });
  await world.record("folder-put-on-page", folder, 200, { method: "PATCH", json: { examPageId: exam2 } });
  await world.record("folder-take-off-page", folder, 200, { method: "PATCH", json: { examPageId: null } });
  const move = `/api/practice-sets/${mixed.str("setId")}/move`;
  await world.record("practice-set-move", move, 200, { method: "POST", json: { folderId: firstPass } });
  const secondPass = (await world.record("practice-set-move-new-folder", move, 200, { method: "POST", json: { newFolderName: "Second Pass" } })).str("id");
  await world.record("practice-set-move-new-folder-taken", move, 409, { method: "POST", json: { newFolderName: "mixed review" } });
  const order = `/api/courses/${courseId}/folder-order`;
  await world.record("folder-order", order, 200, { method: "PUT", json: { examPageId: exam1, folderIds: [week1, week2] } });
  await world.record("folder-order-stale", order, 409, { method: "PUT", json: { examPageId: exam1, folderIds: [week1] } });
  await world.record("course-with-exams", `/api/courses/${courseId}`, 200);

  // Two past exams: one over Midterm's folders, which is on Midterm, and one across both pages, which is on neither.
  const exams = `/api/courses/${courseId}/exams`;
  const onMidterm = (await world.ok(exams, 201, { method: "POST", json: { folderIds: [week1, week2], pool: "all" } })).str("id");
  await world.ok(`/api/exams/${onMidterm}/finish`, 200, { method: "POST", json: { reason: "finished" } });
  const across = (await world.ok(exams, 201, { method: "POST", json: { folderIds: [week1, week2, week3], pool: "all" } })).str("id");
  await world.ok(`/api/exams/${across}/finish`, 200, { method: "POST", json: { reason: "finished" } });
  await world.record("exam-setup-course-exams", exams, 200);

  world.name(semester.str("id"), "5e000000-0000-4000-8000-000000000101");
  world.name(courseId, "c0000000-0000-4000-8000-000000000101");
  world.name(week1, "f0000000-0000-4000-8000-000000000001");
  world.name(week2, "f0000000-0000-4000-8000-000000000002");
  world.name(week3, "f0000000-0000-4000-8000-000000000003");
  world.name(firstPass, "f0000000-0000-4000-8000-000000000011");
  world.name(secondPass, "f0000000-0000-4000-8000-000000000012");
  world.name(exam1, "ce000000-0000-4000-8000-000000000001");
  world.name(exam2, "ce000000-0000-4000-8000-000000000002");
  [set1, set2, set3, mixed].forEach((set, index) => {
    world.name(set.str("setId"), `5e700000-0000-4000-8000-00000000000${String(index + 1)}`);
  });
  world.name(onMidterm, "e0000000-0000-4000-8000-000000000001");
  world.name(across, "e0000000-0000-4000-8000-000000000002");
  await world.close();
  return world;
}

/** Checking and importing set files into a course with folders, a page, and Unsorted. */
async function imports(): Promise<World> {
  const world = await World.boot(14);
  await world.account(STUDENT, "synthetic-session-token");
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const courseId = (await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 101", title: "Invented Nursing" } })).str("id");
  const week1 = (await world.ok(`/api/courses/${courseId}/folders`, 201, { method: "POST", json: { name: "Week 1" } })).str("id");
  const week2 = (await world.ok(`/api/courses/${courseId}/folders`, 201, { method: "POST", json: { name: "Week 2" } })).str("id");
  const exam1 = (await world.ok(`/api/courses/${courseId}/course-exams`, 201, { method: "POST", json: { name: "Exam 1", folderIds: [week2] } })).str("id");

  const terms = { "invented-term": ["Invented term", "A word made up for this fixture."] };
  const depression = (count: number) =>
    source("Invented Depression Care", [finding("Q1", "mood"), safetyChecks("Q2"), finding("Q3", "sleep", "Take action"), finding("Q4", "appetite")].slice(0, count), { terms });
  const anxiety = source("Invented Anxiety Care", [finding("Q1", "panic"), finding("Q2", "breathing")], { terms });
  const sleep = source("Invented Sleep Care", [finding("Q1", "rest")], { terms });
  const exam = source("Invented Depression Exam", [finding("E1", "mood"), finding("E2", "sleep")], { terms, kind: "exam" });
  const broken = JSON.stringify({
    title: "Broken set",
    questions: [{ id: "Q1", type: "single", stem: "Invented.", ask: "Which?", options: [{ t: "One", ok: true }, { t: "Two" }, { t: "Three", ok: true }], rationale: "Invented." }],
  });
  const check = (text: string): CallInit => ({ method: "POST", json: { source: text } });
  await world.record("import-check", "/api/imports/check", 200, check(depression(3)));
  await world.record("import-check-errors", "/api/imports/check", 200, check(broken));
  await world.record("import-check-not-json", "/api/imports/check", 200, check("Here are your questions: {"));
  await world.record("import-check-exam", "/api/imports/check", 200, check(exam));

  const into = (fields: Record<string, Json>): CallInit => ({ method: "POST", json: fields });
  const imported = await world.record("import", "/api/imports", 201, into({ source: depression(3), courseId, decision: "import" }));
  const anxious = await world.record("import-folder", "/api/imports", 201, into({ source: anxiety, title: "Anxiety, renamed", courseId, folderId: week2, decision: "import" }));
  const firstPass = await world.record("import-new-folder", "/api/imports", 201, into({ source: sleep, courseId, folderName: "First Pass", decision: "import" }));
  const second = await world.record("import-new-course", "/api/imports", 201, into({ source: sleep, newCourse: { code: "NURS 102", title: "Invented Second Course", semesterNumber: 1 }, decision: "import" }));
  const conflict = await world.record("import-conflict", "/api/imports", 409, into({ source: depression(4), courseId, folderId: week1, decision: "import" }));
  expect(conflict.get("conflict").value === true, "the same set name did not ask first", conflict.value);
  const replaced = await world.record("import-replace", "/api/imports", 201, into({ source: depression(4), courseId, folderId: week1, decision: "replace" }));
  const separate = await world.record("import-separate", "/api/imports", 201, into({ source: depression(4), courseId, folderId: week1, decision: "separate" }));
  await world.record("import-invalid", "/api/imports", 400, into({ source: broken, courseId, decision: "import" }));
  const examSet = await world.record("import-exam", "/api/imports", 201, into({ source: exam, courseId, folderId: week2, decision: "import" }));

  world.name(semester.str("id"), "5e000000-0000-4000-8000-000000000301");
  world.name(courseId, "c0000000-0000-4000-8000-000000000301");
  world.name(week1, "f0000000-0000-4000-8000-000000000301");
  world.name(week2, "f0000000-0000-4000-8000-000000000302");
  world.name(imported.str("folderId"), "f0000000-0000-4000-8000-000000000303");
  world.name(firstPass.str("folderId"), "f0000000-0000-4000-8000-000000000304");
  world.name(exam1, "ce000000-0000-4000-8000-000000000301");
  world.name(second.str("courseId"), "c0000000-0000-4000-8000-000000000302");
  [imported, anxious, firstPass, second, replaced, separate, examSet].forEach((set, index) => {
    world.name(set.str("setId"), `5e700000-0000-4000-8000-00000000030${String(index + 1)}`);
  });
  await world.close();
  return world;
}
