// Sign-in, the session, changing the password, signing out here and everywhere, the color scheme,
// and sign-up.

import { SIGN_IN_FAILURE_LIMIT } from "../../src/auth/policy";
import { ADMIN, STUDENT, World, expect } from "./world";

export async function recordSessions(): Promise<World[]> {
  return [await session(), await signOutEverywhere(), await palette(), await signUp()];
}

async function session(): Promise<World> {
  const world = await World.boot(1);
  await world.record("health", "/health", 200, { token: null });
  await world.record("session-signed-out", "/api/session", 401, { token: null });
  await world.record("semesters-signed-out", "/api/semesters", 401, { token: null });

  await world.create(STUDENT);
  const signedIn = await world.record("sign-in", "/api/sign-in/password", 200, {
    method: "POST",
    json: { email: STUDENT.email, password: STUDENT.password },
    token: null,
  });
  world.session(signedIn, "synthetic-session-token");
  await world.record("sign-in-wrong-password", "/api/sign-in/password", 401, {
    method: "POST",
    json: { email: STUDENT.email, password: "not-the-password" },
    token: null,
  });
  const locked = { method: "POST", json: { email: "locked@example.com", password: "wrong" }, token: null };
  for (let miss = 0; miss < SIGN_IN_FAILURE_LIMIT; miss += 1) await world.call("/api/sign-in/password", locked);
  await world.record("sign-in-locked", "/api/sign-in/password", 429, locked);
  await world.record("session", "/api/session", 200);

  const password = (currentPassword: string, newPassword: string) => ({ method: "POST", json: { currentPassword, newPassword } });
  await world.record("change-password-wrong", "/api/account/password", 401, password("not-it", "synthetic-pass-3"));
  await world.record("change-password-short", "/api/account/password", 400, password(STUDENT.password, "short"));
  await world.record("change-password-same", "/api/account/password", 400, password(STUDENT.password, STUDENT.password));
  const changed = await world.record("change-password", "/api/account/password", 200, password(STUDENT.password, "synthetic-pass-3"));
  const second = world.session(changed, "synthetic-session-token-2");
  await world.record("sign-out", "/api/sign-out", 200, { method: "POST", token: second });
  await world.record("session-after-sign-out", "/api/session", 401, { token: second });
  await world.close();
  return world;
}

/** Signed in on two devices, she signs out everywhere from one: the other's session ends too. */
async function signOutEverywhere(): Promise<World> {
  const world = await World.boot(22);
  const phone = await world.account(STUDENT, "synthetic-session-token");
  const laptop = await world.signIn(STUDENT.email, STUDENT.password, "synthetic-session-token-2");
  await world.record("sign-out-everywhere", "/api/sign-out/everywhere", 200, { method: "POST", token: phone });
  await world.record("session-after-sign-out-everywhere", "/api/session", 401, { token: laptop });
  await world.record("sign-out-everywhere-signed-out", "/api/sign-out/everywhere", 401, { method: "POST", token: phone });
  await world.close();
  return world;
}

async function palette(): Promise<World> {
  const world = await World.boot(2);
  await world.account(STUDENT, "synthetic-session-token");
  const account = await world.record("palette", "/api/me/palette", 200, { method: "PUT", json: { palette: "slate" } });
  expect(account.str("palette") === "slate", "the palette did not change", account.value);
  await world.record("session-slate", "/api/session", 200);
  await world.close();
  return world;
}

async function signUp(): Promise<World> {
  const world = await World.boot(3);
  // The owner adds her email to the sign-up list from his own session.
  await world.account(ADMIN, "synthetic-admin-token");
  await world.ok("/api/admin/sign-up-emails", 200, { method: "POST", json: { email: "new.user@example.com" } });
  const request = (email: string, password: string) => ({ method: "POST", json: { email, password }, token: null });
  await world.record("sign-up-short-password", "/api/sign-up", 400, request("new.user@example.com", "short"));
  await world.record("sign-up-refused", "/api/sign-up", 403, request("stranger@example.com", "synthetic-pass-3"));
  for (let miss = 1; miss < SIGN_IN_FAILURE_LIMIT; miss += 1) {
    await world.ok("/api/sign-up", 403, request("locked@example.com", "synthetic-pass-3"));
  }
  await world.ok("/api/sign-up", 429, request("locked@example.com", "synthetic-pass-3"));
  await world.record("sign-up-locked", "/api/sign-up", 429, request("locked@example.com", "synthetic-pass-3"));
  const signedUp = await world.record("sign-up", "/api/sign-up", 201, request("new.user@example.com", "synthetic-pass-2"));
  world.session(signedUp, "synthetic-session-token");
  await world.close();
  return world;
}
