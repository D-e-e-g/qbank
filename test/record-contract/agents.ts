// Connect an agent: both sides of a pairing run here, the agent's with no session and hers signed
// in. The app only looks up, answers, lists and revokes, so no recording holds a key.

import { SIGN_IN_FAILURE_LIMIT } from "../../src/auth/policy";
import { question, source } from "./content";
import { ADMIN, STUDENT, World, expect } from "./world";

/** The agent's side starts a pairing; returns its user code, with its dash, and device code. */
async function startPairing(world: World, name: string, scopes: string[], synthetic: string): Promise<{ userCode: string; deviceCode: string }> {
  const started = await world.ok("/api/agent-pairings", 201, { method: "POST", json: { name, scopes }, token: null });
  const userCode = started.str("userCode");
  world.alias(userCode, synthetic);
  world.alias(userCode.replace("-", ""), synthetic.replace("-", ""));
  return { userCode, deviceCode: started.str("deviceCode") };
}

/** The agent picks up its key once she has approved. */
async function pickUp(world: World, deviceCode: string): Promise<string> {
  const delivered = await world.ok("/api/agent-pairings/token", 200, { method: "POST", json: { deviceCode }, token: null });
  return delivered.str("token");
}

/** A whole pairing she answers from her session; returns the agent's key when she approved it. */
export async function pairAgent(world: World, name: string, scopes: string[], answer: "approve"): Promise<string> {
  const { userCode, deviceCode } = await startPairing(world, name, scopes, "BCDF-GHJK");
  await world.ok(`/api/agent-pairings/${answer}`, 200, { method: "POST", json: { userCode } });
  return pickUp(world, deviceCode);
}

export async function recordAgents(): Promise<World[]> {
  const world = await World.boot(9);
  await world.create(STUDENT);
  const admin = await world.account(ADMIN, "synthetic-admin-token");
  world.token = await world.signIn(STUDENT.email, STUDENT.password, "synthetic-session-token");
  await world.record("agent-keys-empty", "/api/agent-keys", 200);
  await world.record("agent-pairing-lookup-not-found", "/api/agent-pairings/lookup", 404, { method: "POST", json: { userCode: "ZZZZ-ZZZZ" } });

  const macbook = await startPairing(world, "My MacBook agent", ["import", "read"], "MNQT-XPJQ");
  await world.record("agent-pairing-lookup", "/api/agent-pairings/lookup", 200, { method: "POST", json: { userCode: macbook.userCode.replace("-", "") } });
  await world.record("agent-pairing-approve", "/api/agent-pairings/approve", 200, { method: "POST", json: { userCode: macbook.userCode } });
  const macbookKey = await pickUp(world, macbook.deviceCode);
  world.alias(macbookKey, "synthetic-agent-key");

  const asked = await startPairing(world, "Study laptop agent", ["import", "manage"], "WHWP-QSTD");
  await world.record("agent-pairing-lookup-manage", "/api/agent-pairings/lookup", 200, { method: "POST", json: { userCode: asked.userCode } });
  await world.record("agent-pairing-deny", "/api/agent-pairings/deny", 200, { method: "POST", json: { userCode: asked.userCode } });
  await world.record("agent-pairing-approve-answered", "/api/agent-pairings/approve", 404, { method: "POST", json: { userCode: asked.userCode } });
  const laptop = await startPairing(world, "Study laptop agent", ["import", "manage"], "KLMN-PQRS");
  await world.ok("/api/agent-pairings/approve", 200, { method: "POST", json: { userCode: laptop.userCode } });
  world.alias(await pickUp(world, laptop.deviceCode), "synthetic-agent-key-2");
  const phone = await startPairing(world, "Old phone agent", ["import"], "TVWX-ZBCD");
  await world.ok("/api/agent-pairings/approve", 200, { method: "POST", json: { userCode: phone.userCode } });
  world.alias(await pickUp(world, phone.deviceCode), "synthetic-agent-key-3");

  // Her own set and one her agent imported with its key.
  const semester = await world.ok("/api/semesters", 201, { method: "POST", json: { number: 1 } });
  const course = await world.ok("/api/courses", 201, { method: "POST", json: { semesterId: semester.str("id"), code: "NURS 401", title: "Invented Agents Course" } });
  const set = (title: string) =>
    source(title, [question("Q1", "An invented client is short of breath."), question("Q2", "An invented client has a racing heart."), question("Q3", "An invented client feels lightheaded.")], {
      desc: "Invented practice set.",
    });
  await world.ok("/api/imports", 201, { method: "POST", json: { source: set("Week 1 - Set 1: Her own set"), courseId: course.str("id"), folderName: "Week 1", decision: "import" } });
  const imported = await world.ok("/api/imports", 201, {
    method: "POST",
    json: { source: set("Week 1 - Set 2: From her agent"), courseId: course.str("id"), folderName: "Week 1", decision: "import" },
    token: macbookKey,
  });
  expect(imported.get("importedByAgent").str("name") === "My MacBook agent", "the agent's import did not name its key", imported.value);
  await world.record("course-imported-by-agent", `/api/courses/${course.str("id")}`, 200);

  const keys = await world.ok("/api/agent-keys", 200);
  const old = keys.find("keys", "name", "Old phone agent").str("id");
  await world.record("agent-key-revoke", `/api/agent-keys/${old}/revoke`, 200, { method: "POST" });
  await world.record("agent-keys", "/api/agent-keys", 200);
  await world.record("agent-key-revoke-not-found", "/api/agent-keys/4d1c3f8e-0000-4000-8000-000000000404/revoke", 404, { method: "POST" });

  // Codes that match nothing lock her answers for a while.
  const miss = { method: "POST", json: { userCode: "GGGG-GGGG" } };
  for (let count = 1; count < SIGN_IN_FAILURE_LIMIT; count += 1) await world.ok("/api/agent-pairings/lookup", 404, miss);
  await world.ok("/api/agent-pairings/lookup", 429, miss);
  await world.record("agent-pairing-lookup-locked", "/api/agent-pairings/lookup", 429, miss);

  // A temporary password from the owner ends her sessions; signed in with it, she chooses her own first.
  await world.ok("/api/admin/student-password", 200, { method: "POST", json: { temporaryPassword: "synthetic-temporary-pass" }, token: admin });
  world.token = await world.signIn(STUDENT.email, "synthetic-temporary-pass", "synthetic-session-token");
  await world.record("agent-pairing-lookup-temporary-password", "/api/agent-pairings/lookup", 403, { method: "POST", json: { userCode: "HHHH-HHHH" } });

  world.name(course.str("id"), "5fd870de-aebb-44ac-b6b3-a7aa431a5fb5");
  world.name(old, "c925031b-bff0-4153-aca1-ab8ff8648f21");
  await world.close();
  return [world];
}
