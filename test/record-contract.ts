// Re-records QBankKit's contract fixtures against the server this file is copied into.
//
// test/record-contract.sh copies this file to apps/api/scripts in a scratch
// checkout and runs it with that package's tsx. The imports below are the
// server's own source; they do not resolve from the iPhone repository.
// The script reads the server, boots a throwaway in-memory database, and
// writes fixtures. It does not fetch and it does not modify the checkout.
//
// Existing recordings keep their ids, dates, and wording. Keys the running
// server now sends on every response are filled in only after a live response
// has shown that key. A key the server stopped sending, or a required key this
// script cannot fill from a live response, stops the run before it writes.

import { copyFileSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { createApp } from "../src/app";
import { ensureAccount, type AccountSpec } from "../src/auth/accounts";
import { createAuth } from "../src/auth/create-auth";
import { applyMigrations, type Queryable } from "../src/db/migrations";
import type { AppDatabase } from "../src/db/postgres";
import { schema as dbSchema } from "../src/db/schema";

const SECRET = "test-secret-that-is-at-least-32-characters";
const BASE = "http://localhost:4318";
const STUDENT: AccountSpec = {
  email: "student@example.com",
  password: "synthetic-pass-1",
  name: "Sam Student",
  role: "student",
};

// The API image published for a commit, the same digest the web app's pin records.
// A newer checkout has no digest here; set QBANK_API_IMAGE for that re-pin.
const IMAGES: Record<string, string> = {
  d0db2444f2c236c3591aab3d9a0532631385ff85:
    "ghcr.io/d-e-e-g/nclex-qbank-api@sha256:1b96e033f30450ce38b951cd77704a7b9afe0f216b8e50a554720b56ba4513bf",
};

const PHARMA = "70000000-0000-4000-8000-000000000001";
const SPANISH = "70000000-0000-4000-8000-000000000002";
const SYSTEMS = "70000000-0000-4000-8000-000000000003";
const SEMESTER_1 = "3d9a9957-5eb2-4949-b1f7-086f1e51ff61";
const SEMESTER_2 = "3d9a9957-5eb2-4949-b1f7-086f1e51ff62";
const NURS = "c0000000-0000-4000-8000-000000000101";
const CARDIAC_FOLDER = "f0000000-0000-4000-8000-000000000701";
const UNSORTED_FOLDER = "f0000000-0000-4000-8000-000000000702";
const PAGE = "ce000000-0000-4000-8000-000000000701";
const CARDIAC_SET = "5e700000-0000-4000-8000-000000000701";
const UNSORTED_SET = "5e700000-0000-4000-8000-000000000702";
const QUESTION_1 = "9e000000-0000-4000-8000-000000070001";
const QUESTION_2 = "9e000000-0000-4000-8000-000000070002";
const QUESTION_3 = "9e000000-0000-4000-8000-000000070003";

// Keys a current response always carries. availableAt is absent on purpose:
// the maker omits it when it is null, and the schema does not require it.
const FILL: Record<string, (object: Record<string, unknown>) => unknown> = {
  badge: () => null,
  linkUrl: () => null,
  importedByAgent: () => null,
  deletedByAgent: () => null,
  archivedAt: () => null,
  setDeletedAt: () => null,
  deletedAt: () => null,
  palette: () => "dusk",
  examSets: () => [],
  topics: () => [],
  examPages: () => [],
  kind: (object) => {
    if (typeof object.code === "string" && object.code !== "") return "course";
    if (object.semester && typeof object.semester === "object") return "course";
    throw new Error(`refusing to invent kind on ${JSON.stringify(object).slice(0, 180)}`);
  },
};

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

interface Schema {
  type?: string | string[];
  properties?: Record<string, Schema>;
  required?: string[];
  items?: Schema;
  additionalProperties?: boolean | Schema | Record<string, never>;
  oneOf?: Schema[];
  anyOf?: Schema[];
  allOf?: Schema[];
  $ref?: string;
}

const commit = process.argv[2];
const fixturesDir = process.argv[3];
const openapiPath = process.argv[4];
if (!commit || !fixturesDir || !openapiPath || !/^[0-9a-f]{40}$/.test(commit)) {
  throw new Error("usage: record-contract.ts <full-commit> <Fixtures-dir> <openapi.json>");
}

const spec = JSON.parse(readFileSync(openapiPath, "utf8")) as {
  paths: Record<string, Record<string, { responses?: Record<string, Schema> }>>;
  components: { schemas: Record<string, Schema> };
};

function resolve(schema: Schema | undefined, depth = 0): Schema {
  if (!schema || depth > 24) return schema ?? {};
  if (schema.$ref) {
    const name = schema.$ref.split("/").pop() ?? "";
    const target = spec.components.schemas[name];
    if (!target) throw new Error(`missing schema ${schema.$ref}`);
    return resolve(target, depth + 1);
  }
  if (schema.allOf) {
    const merged: Schema = { type: "object", properties: {}, required: [] };
    for (const part of schema.allOf) {
      const sub = resolve(part, depth + 1);
      Object.assign(merged.properties!, sub.properties ?? {});
      merged.required!.push(...(sub.required ?? []));
      if (sub.items) merged.items = sub.items;
      if (sub.additionalProperties !== undefined) merged.additionalProperties = sub.additionalProperties;
      if (sub.type && !sub.properties) merged.type = sub.type;
    }
    for (const [key, value] of Object.entries(schema)) {
      if (key === "allOf") continue;
      if (key === "properties") Object.assign(merged.properties!, value as Schema["properties"]);
      else if (key === "required") merged.required!.push(...(value as string[]));
      else (merged as Record<string, unknown>)[key] = value;
    }
    return merged;
  }
  return schema;
}

function variants(schema: Schema): Schema[] {
  const resolved = resolve(schema);
  const list = resolved.oneOf ?? resolved.anyOf;
  if (!list) return [resolved];
  return list.flatMap((part) => variants(part));
}

function matchTemplate(template: string, path: string): boolean {
  const left = template.split("/");
  const right = path.split("/");
  return left.length === right.length && left.every((part, index) => part.startsWith("{") || part === right[index]);
}

function operation(method: string, path: string) {
  const direct = spec.paths[path]?.[method.toLowerCase()];
  if (direct) return direct;
  for (const [template, item] of Object.entries(spec.paths)) {
    if (matchTemplate(template, path) && item[method.toLowerCase()]) return item[method.toLowerCase()];
  }
  return undefined;
}

function responseSchema(method: string, path: string, status: number): Schema | undefined {
  const op = operation(method, path);
  if (!op) throw new Error(`no operation ${method} ${path}`);
  const response = op.responses?.[String(status)];
  if (!response) throw new Error(`no response ${status} for ${method} ${path}`);
  const resolved = resolve(response);
  const content = (resolved as { content?: Record<string, { schema?: Schema }> }).content;
  const json = content?.["application/json"] ?? content?.["application/problem+json"];
  return json?.schema ? resolve(json.schema) : undefined;
}

function queryable(client: PGlite): Queryable {
  return {
    async query<T>(statement: string, params: unknown[] = []): Promise<T[]> {
      const result = await client.query<Record<string, unknown>>(statement, params);
      return result.rows as T[];
    },
    transaction(run) {
      return client.transaction(async (tx) => {
        const inner: Queryable = {
          async query<T>(statement: string, params: unknown[] = []): Promise<T[]> {
            const result = await tx.query<Record<string, unknown>>(statement, params);
            return result.rows as T[];
          },
          transaction: (nested) => nested(inner),
        };
        return run(inner);
      });
    },
  };
}

interface CallResult {
  status: number;
  body: Json;
}

async function call(
  app: ReturnType<typeof createApp>,
  path: string,
  token: string | null,
  init: { method?: string; json?: unknown } = {},
): Promise<CallResult> {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (init.json !== undefined) headers["content-type"] = "application/json";
  const response = await app.request(path, {
    method: init.method ?? "GET",
    headers,
    body: init.json === undefined ? null : JSON.stringify(init.json),
  });
  const text = await response.text();
  return { status: response.status, body: text.length > 0 ? (JSON.parse(text) as Json) : null };
}

function expectStatus(result: CallResult, status: number, what: string): Record<string, Json> {
  if (result.status !== status || result.body === null || typeof result.body !== "object" || Array.isArray(result.body)) {
    throw new Error(`${what} returned ${result.status}: ${JSON.stringify(result.body).slice(0, 500)}`);
  }
  return result.body;
}

function question(id: string, stem: string) {
  return {
    id,
    type: "single",
    topic: "Perfusion",
    cj: "Analyze cues",
    need: "Physiological Adaptation",
    diff: 4,
    stem,
    ask: "Which action first?",
    options: [
      { t: "Sit the client up", ok: true, why: "Upright eases the work of breathing." },
      { t: "Offer a book", why: "Reading does not change oxygenation." },
      { t: "Dim the lights", why: "The lights are not the problem." },
    ],
    rationale: "Airway and breathing come before comfort measures.",
    takeaway: "Raise the head of the bed when breathing is hard.",
    terms: [] as string[],
    src: "Ch 26 slide 22",
  };
}

function source(title: string, questions: ReturnType<typeof question>[]) {
  return JSON.stringify({
    title,
    desc: "Invented practice questions.",
    terms: {},
    questions,
  });
}

const proved = new Set<string>();

function observe(value: unknown) {
  if (Array.isArray(value)) {
    for (const item of value) observe(item);
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, inner] of Object.entries(value)) {
    if (key in FILL) proved.add(key);
    observe(inner);
  }
}

function rewrite(value: Json, ids: Map<string, string>): Json {
  if (typeof value === "string") return (ids.get(value) as Json) ?? value;
  if (Array.isArray(value)) return value.map((item) => rewrite(item, ids));
  if (value && typeof value === "object") {
    const out: { [key: string]: Json } = {};
    for (const [key, inner] of Object.entries(value)) out[key] = rewrite(inner, ids);
    return out;
  }
  return value;
}

function envelope(method: string, path: string, status: number, body: Json, requestBody: Json = null) {
  return {
    recordedFrom: commit,
    request: {
      method,
      path,
      query: {},
      authorization: "Bearer synthetic-session-token",
      body: requestBody,
    },
    response: { status, headers: {}, body },
  };
}

function choose(body: unknown, schema: Schema): Schema {
  let best = resolve(schema);
  let bestScore = -100;
  for (const candidate of variants(schema)) {
    let score = 0;
    if (body === null) score = candidate.type === "null" ? 8 : -2;
    else if (Array.isArray(body)) score = candidate.items || candidate.type === "array" ? 4 : -2;
    else if (body && typeof body === "object") {
      const props = candidate.properties ?? {};
      const keys = Object.keys(body);
      score = keys.filter((key) => key in props).length;
      score -= (candidate.required ?? []).filter((key) => !(key in (body as object))).length * 3;
      if (candidate.properties) score += 1;
    }
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

function fillValue(value: unknown, schema: Schema | undefined, where: string) {
  if (!schema || value === null || value === undefined) return;
  const chosen = choose(value, schema);
  if (Array.isArray(value)) {
    if (chosen.items) for (const item of value) fillValue(item, chosen.items, `${where}[]`);
    return;
  }
  if (!value || typeof value !== "object") return;
  const object = value as Record<string, unknown>;
  const props = chosen.properties ?? {};
  for (const [key, property] of Object.entries(props)) {
    if (!(key in object)) {
      const produce = FILL[key];
      if (!produce) continue;
      if (!proved.has(key)) {
        throw new Error(`${where}.${key} is missing and no live response showed ${key}`);
      }
      object[key] = produce(object);
    } else {
      fillValue(object[key], property, `${where}.${key}`);
    }
  }
}

function missingRequired(value: unknown, schema: Schema | undefined, where: string, missing: string[]) {
  if (!schema || value === null || value === undefined) return;
  const chosen = choose(value, schema);
  if (Array.isArray(value)) {
    if (chosen.items) for (const item of value) missingRequired(item, chosen.items, `${where}[]`, missing);
    return;
  }
  if (!value || typeof value !== "object") return;
  const object = value as Record<string, unknown>;
  for (const key of chosen.required ?? []) {
    if (!(key in object)) missing.push(`${where}.${key}`);
  }
  for (const [key, property] of Object.entries(chosen.properties ?? {})) {
    if (key in object) missingRequired(object[key], property, `${where}.${key}`, missing);
  }
}

async function boot() {
  const client = new PGlite();
  await applyMigrations(queryable(client));
  const database = drizzle(client, { schema: dbSchema }) as unknown as AppDatabase;
  const auth = createAuth({ db: database, secret: SECRET, baseURL: BASE });
  await ensureAccount(auth, STUDENT);
  const app = createApp({ version: "0000000", auth: { auth, db: database } });
  const signed = expectStatus(
    await call(app, "/api/sign-in/password", null, { method: "POST", json: { email: STUDENT.email, password: STUDENT.password } }),
    200,
    "sign-in",
  );
  observe(signed);
  const token = String(signed.token);
  return {
    client,
    app,
    token,
    async ok(path: string, status: number, init?: { method?: string; json?: unknown }) {
      const result = await call(app, path, token, init);
      const body = expectStatus(result, status, `${init?.method ?? "GET"} ${path}`);
      observe(body);
      return body;
    },
  };
}

async function recordTopics() {
  const server = await boot();
  const semester1 = await server.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await server.ok("/api/courses", 201, {
    method: "POST",
    json: { semesterId: semester1.id, code: "NURS 101", title: "Invented Nursing Basics" },
  });
  const semester2 = await server.ok("/api/semesters", 201, { method: "POST", json: { number: 2 } });
  await server.ok(`/api/semesters/${String(semester2.id)}`, 200, { method: "PATCH", json: { archived: true } });
  const pharma = await server.ok("/api/topics", 201, { method: "POST", json: { title: "Invented Pharmacology Review" } });
  const cardiac = await server.ok("/api/imports", 201, {
    method: "POST",
    json: {
      source: source("Invented cardiac drugs", [
        question("Q1", "A client is short of breath."),
        question("Q2", "A client has a racing heart."),
      ]),
      courseId: pharma.id,
      folderName: "Cardiac drugs",
      decision: "import",
    },
  });
  if (cardiac.importedByAgent !== null) throw new Error("an app import named an agent");
  const loose = await server.ok("/api/imports", 201, {
    method: "POST",
    json: {
      source: source("Invented loose questions", [question("Q3", "A client feels lightheaded.")]),
      courseId: pharma.id,
      decision: "import",
    },
  });
  if (loose.folderName !== "Unsorted") throw new Error(`loose import filed under ${String(loose.folderName)}`);
  const drafted = await server.ok(`/api/courses/${String(pharma.id)}`, 200);
  const folders = drafted.folders as { id: string; name: string }[];
  const cardiacFolder = folders.find((folder) => folder.name === "Cardiac drugs");
  if (!cardiacFolder) throw new Error("Cardiac drugs folder was not created");
  const page = await server.ok(`/api/courses/${String(pharma.id)}/course-exams`, 201, {
    method: "POST",
    json: { name: "Page 1", folderIds: [cardiacFolder.id], linkUrl: "https://primer.invalid/cardiac-drugs" },
  });
  if (!("badge" in page) || page.badge !== null) throw new Error(`page badge was ${JSON.stringify(page.badge)}`);
  if (page.linkUrl !== "https://primer.invalid/cardiac-drugs") throw new Error(`page link was ${String(page.linkUrl)}`);
  const beforeAnswer = await server.ok(`/api/courses/${String(pharma.id)}`, 200);
  const beforeFolders = beforeAnswer.folders as { name: string; sets: { questionIds: string[] }[] }[];
  const cardiacQuestion = beforeFolders.find((folder) => folder.name === "Cardiac drugs")?.sets[0]?.questionIds[0];
  if (!cardiacQuestion) throw new Error("cardiac set has no question");
  const attempt = await server.ok("/api/attempts", 201, {
    method: "POST",
    json: {
      clientAttemptId: "11111111-1111-4111-8111-111111111701",
      questionId: cardiacQuestion,
      response: { type: "single", choice: 1 },
      guessed: false,
    },
  });
  if (attempt.status !== "incorrect") throw new Error(`expected a wrong answer, got ${String(attempt.status)}`);
  const spanish = await server.ok("/api/topics", 201, { method: "POST", json: { title: "Invented Spanish Verbs" } });
  await server.ok(`/api/courses/${String(spanish.id)}`, 200, { method: "PATCH", json: { archived: true } });

  const catalog = await server.ok("/api/semesters", 200);
  const topic = await server.ok(`/api/courses/${String(pharma.id)}`, 200);
  await server.ok("/api/me/place", 200, { method: "PUT", json: { courseId: pharma.id } });
  const place = await server.ok("/api/me/place", 200);
  const systems = await server.ok("/api/topics", 201, { method: "POST", json: { title: "Invented Systems Design" } });
  const ordered = await server.ok("/api/topic-order", 200, {
    method: "PUT",
    json: { topicIds: [systems.id, pharma.id, spanish.id] },
  });

  const detailFolders = topic.folders as {
    id: string;
    name: string;
    examPageId: Json;
    sets: { id: string; questionIds: string[]; answeredCount: number; questionCount: number; importedByAgent: Json }[];
    examSets: unknown;
  }[];
  const byName = (name: string) => detailFolders.find((folder) => folder.name === name);
  const cardiacDetail = byName("Cardiac drugs");
  const unsortedDetail = byName("Unsorted");
  if (detailFolders.map((folder) => folder.name).join(",") !== "Cardiac drugs,Unsorted") {
    throw new Error(`folder order ${detailFolders.map((folder) => folder.name).join(",")}`);
  }
  if (!cardiacDetail || cardiacDetail.sets.length !== 1 || cardiacDetail.sets[0].questionIds.length !== 2) {
    throw new Error("cardiac set did not hold two questions");
  }
  if (cardiacDetail.sets[0].answeredCount !== 1 || cardiacDetail.examPageId === null) {
    throw new Error("cardiac folder was not answered on the page");
  }
  if (!unsortedDetail || unsortedDetail.sets.length !== 1 || unsortedDetail.sets[0].questionIds.length !== 1) {
    throw new Error("unsorted set did not hold one question");
  }
  if (unsortedDetail.sets[0].answeredCount !== 0 || unsortedDetail.examPageId !== null) {
    throw new Error("unsorted folder was not the unanswered one");
  }
  if (!("examSets" in cardiacDetail)) throw new Error("folder omitted examSets");
  if (topic.kind !== "topic" || topic.code !== "" || topic.semester !== null) throw new Error("topic detail is not a topic");
  if (topic.title !== "Invented Pharmacology Review" || topic.questionCount !== 3 || topic.folderCount !== 2) {
    throw new Error(`unexpected topic counts ${JSON.stringify({ title: topic.title, questions: topic.questionCount, folders: topic.folderCount })}`);
  }
  const exams = topic.exams as { name: string; linkUrl: Json; badge: Json; folderIds: string[] }[];
  if (exams.length !== 1 || exams[0].name !== "Page 1" || exams[0].linkUrl !== "https://primer.invalid/cardiac-drugs" || exams[0].badge !== null) {
    throw new Error(`unexpected pages ${JSON.stringify(exams)}`);
  }
  const topics = catalog.topics as { title: string; kind: string; code: string; archivedAt: Json }[];
  if (topics.map((item) => item.title).join("|") !== "Invented Pharmacology Review|Invented Spanish Verbs") {
    throw new Error(`catalog topics ${topics.map((item) => item.title).join("|")}`);
  }
  if (topics.some((item) => item.kind !== "topic" || item.code !== "")) throw new Error("catalog topic was not a topic");
  if (topics[0].archivedAt !== null || topics[1].archivedAt === null) throw new Error("catalog archived the wrong topic");
  const semesters = catalog.semesters as { name: string; archivedAt: Json; courses: { code: string; kind: string }[] }[];
  if (semesters.map((item) => item.name).join("|") !== "Semester 1|Semester 2") throw new Error("semester names changed");
  if (semesters[0].archivedAt !== null || semesters[1].archivedAt === null) throw new Error("semester archive did not stick");
  if (semesters[0].courses.map((item) => item.code).join(",") !== "NURS 101" || semesters[0].courses[0].kind !== "course") {
    throw new Error("catalog course was not NURS 101");
  }
  const order = ordered.topics as { id: string; sortOrder: number }[];
  if (order.map((item) => item.id).join(",") !== [systems.id, pharma.id, spanish.id].join(",")) {
    throw new Error("topic order did not follow the request");
  }
  if (order.map((item) => item.sortOrder).join(",") !== "1,2,3") throw new Error(`sort orders ${order.map((item) => item.sortOrder).join(",")}`);
  if (place.courseId !== pharma.id) throw new Error("study place did not keep the topic");

  const proofFolder = await server.ok(`/api/courses/${String(course.id)}/folders`, 201, { method: "POST", json: { name: "Proof" } });
  if (!("examSets" in proofFolder)) throw new Error("a new folder omitted examSets");
  const proofPage = await server.ok(`/api/courses/${String(course.id)}/course-exams`, 201, {
    method: "POST",
    json: { name: "Proof page", folderIds: [proofFolder.id] },
  });
  const preview = await server.ok(`/api/course-exams/${String(proofPage.id)}/delete-preview`, 200);
  // 204 has no JSON body.
  const removed = await call(
    server.app,
    `/api/course-exams/${String(proofPage.id)}?confirm=${encodeURIComponent(String(preview.confirm))}`,
    server.token,
    { method: "DELETE" },
  );
  if (removed.status !== 204) throw new Error(`delete page returned ${removed.status}: ${JSON.stringify(removed.body).slice(0, 300)}`);
  const deleted = await server.ok(`/api/courses/${String(course.id)}/deleted`, 200);
  const deletedPages = deleted.examPages as { badge?: Json; deletedByAgent?: Json }[];
  if (!deletedPages?.length || !("badge" in deletedPages[0]) || !("deletedByAgent" in deletedPages[0])) {
    throw new Error(`deleted pages omitted badge or deletedByAgent: ${JSON.stringify(deleted.examPages).slice(0, 300)}`);
  }
  const session = await server.ok("/api/session", 200);
  const user = session.user as { palette?: string };
  if (user.palette !== "dusk") throw new Error(`a new account palette was ${String(user.palette)}`);
  // An exam is a study session. The export always sends deletedAt on one; prove that on a live row.
  await server.ok(`/api/courses/${String(pharma.id)}/exams`, 201, {
    method: "POST",
    json: { folderIds: [cardiacDetail.id], pool: "all" },
  });
  const exported = await server.ok("/api/me/export", 200);
  const sessions = exported.studySessions as { deletedAt?: Json }[];
  const questions = exported.questions as { setDeletedAt?: Json }[];
  if (!sessions?.length || !("deletedAt" in sessions[0])) throw new Error("export study session omitted deletedAt");
  if (!questions?.length || !("setDeletedAt" in questions[0])) throw new Error("export question omitted setDeletedAt");
  const job = await call(server.app, "/api/question-jobs/00000000-0000-4000-8000-000000000000", server.token);
  if (job.body && typeof job.body === "object" && !Array.isArray(job.body) && "availableAt" in job.body) {
    throw new Error(`question maker error included availableAt: ${JSON.stringify(job.body)}`);
  }

  const ids = new Map<string, string>([
    [String(semester1.id), SEMESTER_1],
    [String(semester2.id), SEMESTER_2],
    [String(course.id), NURS],
    [String(pharma.id), PHARMA],
    [String(spanish.id), SPANISH],
    [String(systems.id), SYSTEMS],
    [cardiacDetail.id, CARDIAC_FOLDER],
    [unsortedDetail.id, UNSORTED_FOLDER],
    [String((topic.exams as { id: string }[])[0].id), PAGE],
    [cardiacDetail.sets[0].id, CARDIAC_SET],
    [unsortedDetail.sets[0].id, UNSORTED_SET],
    [cardiacDetail.sets[0].questionIds[0], QUESTION_1],
    [cardiacDetail.sets[0].questionIds[1], QUESTION_2],
    [unsortedDetail.sets[0].questionIds[0], QUESTION_3],
  ]);

  const recorded = {
    "semesters-with-topics": envelope("GET", "/api/semesters", 200, rewrite(catalog as Json, ids)),
    topic: envelope("GET", `/api/courses/${PHARMA}`, 200, rewrite(topic as Json, ids)),
    "place-topic": envelope("GET", "/api/me/place", 200, rewrite(place as Json, ids)),
    "topic-create": envelope("POST", "/api/topics", 201, rewrite(systems as Json, ids), { title: "Invented Systems Design" }),
    "topic-order": envelope(
      "PUT",
      "/api/topic-order",
      200,
      rewrite(ordered as Json, ids),
      { topicIds: [SYSTEMS, PHARMA, SPANISH] },
    ),
  };
  await server.client.close();
  return recorded;
}

function patchFixtures() {
  const directory = join(fixturesDir, "contract");
  const names = readdirSync(directory).filter((name) => name.endsWith(".json")).sort();
  let filled = 0;
  const written: { name: string; json: unknown }[] = [];
  for (const name of names) {
    const fixture = JSON.parse(readFileSync(join(directory, name), "utf8")) as {
      recordedFrom: string;
      request: { method: string; path: string };
      response: { status: number; body: unknown };
    };
    const body = fixture.response.body;
    if (body !== null) {
      const response = responseSchema(fixture.request.method, fixture.request.path, fixture.response.status);
      const before = JSON.stringify(body);
      fillValue(body, response, name);
      if (JSON.stringify(body) !== before) filled += 1;
      const missing: string[] = [];
      missingRequired(body, response, name, missing);
      if (missing.length > 0) {
        throw new Error(`${name} is still missing required keys:\n${missing.join("\n")}`);
      }
    }
    fixture.recordedFrom = commit;
    written.push({ name, json: fixture });
  }
  return { written, filled };
}

const recorded = await recordTopics();
const patched = patchFixtures();
for (const key of ["badge", "linkUrl", "kind", "importedByAgent", "examSets", "archivedAt", "topics", "examPages", "deletedByAgent", "palette", "setDeletedAt", "deletedAt"]) {
  if (!proved.has(key)) throw new Error(`refusing to write: never saw live key ${key}`);
}

const image = process.env.QBANK_API_IMAGE || IMAGES[commit];
if (!image) throw new Error(`No API image for ${commit}. Set QBANK_API_IMAGE to the image built from it.`);

for (const file of patched.written) {
  writeFileSync(join(fixturesDir, "contract", file.name), `${JSON.stringify(file.json, null, 2)}\n`);
}
for (const [name, fixture] of Object.entries(recorded)) {
  writeFileSync(join(fixturesDir, "contract", `${name}.json`), `${JSON.stringify(fixture, null, 2)}\n`);
}
copyFileSync(openapiPath, join(fixturesDir, "openapi.json"));
writeFileSync(
  join(fixturesDir, "pin.json"),
  `${JSON.stringify({ repository: "D-e-e-g/qbank-server", commit, path: "apps/api/openapi.json", image }, null, 2)}\n`,
);
console.log(`recorded ${Object.keys(recorded).length} topic fixtures, patched ${patched.filled} existing fixtures at ${commit}`);
