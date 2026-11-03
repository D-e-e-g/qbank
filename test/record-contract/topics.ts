// Study topics beside semesters: the catalog, a topic's page, her place, making one, and her order.

import { question, source } from "./content";
import { STUDENT, World, expect } from "./world";

export async function recordTopics(): Promise<World[]> {
  const world = await World.boot(4);
  await world.account(STUDENT, "synthetic-session-token");
  const semester1 = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, {
    method: "POST",
    json: { semesterId: semester1.str("id"), code: "NURS 101", title: "Invented Nursing Basics" },
  });
  const semester2 = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 2 } });
  await world.ok(`/api/semesters/${semester2.str("id")}`, 200, { method: "PATCH", json: { archived: true } });
  const pharma = await world.ok("/api/topics", 201, { method: "POST", json: { title: "Invented Pharmacology Review" } });
  const pharmaId = pharma.str("id");
  const cardiac = await world.ok("/api/imports", 201, {
    method: "POST",
    json: {
      source: source("Invented cardiac drugs", [question("Q1", "A client is short of breath."), question("Q2", "A client has a racing heart.")]),
      courseId: pharmaId,
      folderName: "Cardiac drugs",
      decision: "import",
    },
  });
  expect(cardiac.isNull("importedByAgent"), "an app import named an agent", cardiac.value);
  const loose = await world.ok("/api/imports", 201, {
    method: "POST",
    json: { source: source("Invented loose questions", [question("Q3", "A client feels lightheaded.")]), courseId: pharmaId, decision: "import" },
  });
  expect(loose.str("folderName") === "Unsorted", "a loose import was not filed under Unsorted", loose.value);
  const cardiacFolder = (await world.ok(`/api/courses/${pharmaId}`, 200)).find("folders", "name", "Cardiac drugs");
  const page = await world.ok(`/api/courses/${pharmaId}/course-exams`, 201, {
    method: "POST",
    json: { name: "Page 1", folderIds: [cardiacFolder.str("id")], linkUrl: "https://primer.invalid/cardiac-drugs" },
  });
  const cardiacSet = cardiacFolder.list("sets")[0];
  expect(cardiacSet !== undefined, "the cardiac folder has no set");
  await world.ok("/api/attempts", 201, {
    method: "POST",
    json: {
      clientAttemptId: "11111111-1111-4111-8111-111111111701",
      questionId: cardiacSet.list("questionIds")[0]?.str() ?? "",
      response: { type: "single", choice: 1 },
      guessed: false,
    },
  });
  const spanish = await world.ok("/api/topics", 201, { method: "POST", json: { title: "Invented Spanish Verbs" } });
  await world.ok(`/api/courses/${spanish.str("id")}`, 200, { method: "PATCH", json: { archived: true } });

  const catalog = await world.record("semesters-with-topics", "/api/semesters", 200);
  const topic = await world.record("topic", `/api/courses/${pharmaId}`, 200);
  await world.ok("/api/me/place", 200, { method: "PUT", json: { courseId: pharmaId } });
  await world.record("place-topic", "/api/me/place", 200);
  const systems = await world.record("topic-create", "/api/topics", 201, { method: "POST", json: { title: "Invented Systems Design" } });
  await world.record("topic-order", "/api/topic-order", 200, { method: "PUT", json: { topicIds: [systems.str("id"), pharmaId, spanish.str("id")] } });

  expect(topic.list("folders").map((folder) => folder.str("name")).join(",") === "Cardiac drugs,Unsorted", "the topic's folders changed", topic.value);
  expect(topic.list("exams")[0]?.isNull("badge") === true, "a new page has a badge", topic.value);
  expect(catalog.list("topics").map((item) => item.isNull("archivedAt")).join(",") === "true,false", "the catalog archived the wrong topic", catalog.value);
  const unsorted = topic.find("folders", "name", "Unsorted");
  const unsortedSet = unsorted.list("sets")[0];
  expect(unsortedSet !== undefined, "the Unsorted folder has no set");

  world.name(semester1.str("id"), "3d9a9957-5eb2-4949-b1f7-086f1e51ff61");
  world.name(semester2.str("id"), "3d9a9957-5eb2-4949-b1f7-086f1e51ff62");
  world.name(course.str("id"), "c0000000-0000-4000-8000-000000000101");
  world.name(pharmaId, "70000000-0000-4000-8000-000000000001");
  world.name(spanish.str("id"), "70000000-0000-4000-8000-000000000002");
  world.name(systems.str("id"), "70000000-0000-4000-8000-000000000003");
  world.name(cardiacFolder.str("id"), "f0000000-0000-4000-8000-000000000701");
  world.name(unsorted.str("id"), "f0000000-0000-4000-8000-000000000702");
  world.name(page.str("id"), "ce000000-0000-4000-8000-000000000701");
  world.name(cardiacSet.str("id"), "5e700000-0000-4000-8000-000000000701");
  world.name(unsortedSet.str("id"), "5e700000-0000-4000-8000-000000000702");
  [...cardiacSet.list("questionIds"), ...unsortedSet.list("questionIds")].forEach((id, index) => {
    world.name(id.str(), `9e000000-0000-4000-8000-00000007000${String(index + 1)}`);
  });
  await world.close();
  return [world];
}
