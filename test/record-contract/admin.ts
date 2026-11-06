// The admin's look at a user account: which accounts it may look at, and that the server refuses
// its writes to them. Choosing the account stays on the web, so no recording changes it.

import { ADMIN, STUDENT, World, expect } from "./world";

const SECOND = { email: "second.user@example.com", password: "synthetic-pass-2", name: "Second User", role: "student" as const };

export async function recordAdmin(): Promise<World[]> {
  const none = await World.boot(20);
  await none.account(ADMIN, "synthetic-session-token");
  const empty = await none.record("admin-students-none", "/api/admin/students", 200);
  expect(empty.isNull("viewingId"), "an admin with no user account yet looks at nobody", empty.value);
  await none.close();

  const world = await World.boot(21);
  await world.account(ADMIN, "synthetic-session-token");
  await world.account(STUDENT, "synthetic-student-token");
  await world.account(SECOND, "synthetic-student-token-2");
  const list = await world.record("admin-students", "/api/admin/students", 200);
  expect(list.list("students").length === 2, "the admin lists both user accounts", list.value);
  await world.record("admin-read-only", "/api/semesters", 403, { method: "POST", json: { number: 1 } });
  await world.close();
  return [none, world];
}
