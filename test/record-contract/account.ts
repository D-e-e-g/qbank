// Deleting her own user account, and every way the server refuses it.

import { FakeModel, never } from "../../src/question-maker/fake-model";
import { QuestionRunner } from "../../src/question-maker/runner";
import { SIGN_IN_FAILURE_LIMIT } from "../../src/auth/policy";
import { pairAgent } from "./agents";
import { ADMIN, STUDENT, World, expect } from "./world";

const HER = { ...STUDENT, password: "synthetic-pass-2" };
const remove = (password?: string) => ({ method: "DELETE", json: password === undefined ? {} : { password } });

export async function recordAccountDeletion(): Promise<World[]> {
  return [await deleted(), await temporaryPassword(), await locked(), await unavailable()];
}

/** The delete itself, after the refusals that leave her account as it was. */
async function deleted(): Promise<World> {
  const fake = new FakeModel().on("sample", never);
  let runner: QuestionRunner | undefined;
  const world = await World.boot(5, {
    questionMaker: (db) => {
      runner = new QuestionRunner({ db, client: fake, sweepMs: 0, log: () => undefined });
      return { settings: { accounts: [HER.email], dailyLimit: 50 }, runner };
    },
  });
  const admin = await world.account(ADMIN, "synthetic-session-token");
  const first = await world.account(HER, "synthetic-session-token");
  world.token = first;
  const second = await world.signIn(HER.email, HER.password, "synthetic-session-token-2");

  await world.record("account-delete-admin", "/api/me", 403, { ...remove(ADMIN.password), token: admin });
  await world.record("account-delete-wrong-password", "/api/me", 401, remove("not-it"));
  await world.record("account-delete-no-password", "/api/me", 400, remove());

  const key = await pairAgent(world, "My MacBook agent", ["import", "read"], "approve");
  world.alias(key, "synthetic-agent-key");
  await world.record("account-delete-agent-key", "/api/me", 403, { ...remove(HER.password), token: key });

  // A set still being made: its model never answers until the job is cancelled.
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 101", title: "Invented Basics" } });
  const job = await world.ok("/api/question-jobs", 202, {
    method: "POST",
    json: {
      courseId: course.str("id"),
      folderName: "Week 1",
      materialKind: "notes",
      material: { text: "Invented lecture notes.\nSlide 1: invented topics for a test." },
      level: "exam",
      count: 10,
      examTwins: false,
    },
  });
  await fake.started("sample");
  await world.record("account-delete-in-use", "/api/me", 409, remove(HER.password));
  await world.ok(`/api/question-jobs/${job.str("id")}/cancel`, 200, { method: "POST" });
  await runner?.idle();

  const gone = await world.record("account-delete", "/api/me", 200, remove(HER.password));
  expect(gone.str("status") === "deleted", "the account was not deleted", gone.value);
  await world.record("session-after-account-delete", "/api/session", 401, { token: second });
  await world.record("account-delete-signed-out", "/api/me", 401, remove(HER.password));
  await runner?.stop();
  await world.close();
  return world;
}

/** The owner gave her a temporary password: she chooses her own before anything else. */
async function temporaryPassword(): Promise<World> {
  const world = await World.boot(6);
  await world.create(HER);
  await world.account(ADMIN, "synthetic-admin-token");
  await world.ok("/api/admin/student-password", 200, { method: "POST", json: { temporaryPassword: "synthetic-temporary-pass" } });
  world.token = await world.signIn(HER.email, "synthetic-temporary-pass", "synthetic-session-token");
  await world.record("account-delete-temporary-password", "/api/me", 403, remove("synthetic-temporary-pass"));
  await world.close();
  return world;
}

/** Wrong passwords lock deleting, as they lock sign-in. */
async function locked(): Promise<World> {
  const world = await World.boot(7);
  await world.account(HER, "synthetic-session-token");
  for (let miss = 1; miss < SIGN_IN_FAILURE_LIMIT; miss += 1) await world.ok("/api/me", 401, remove("not-it"));
  await world.ok("/api/me", 429, remove("not-it"));
  await world.record("account-delete-locked", "/api/me", 429, remove("not-it"));
  await world.close();
  return world;
}

/** A server with sign-in not configured answers every account route 503. */
async function unavailable(): Promise<World> {
  const world = await World.boot(8, { auth: false });
  world.token = "synthetic-session-token";
  await world.record("account-delete-unavailable", "/api/me", 503, remove(HER.password));
  await world.close();
  return world;
}
