// One throwaway server for one scenario: the real app over an in-memory database, driven only
// through its routes, keeping every exchange a fixture is made from.
//
// Recorded exchanges keep what the server sent, with three rewrites so a re-record changes only
// what the server changed: every id the server made becomes a fixed synthetic one (named by the
// scenario where a test names it, numbered in the order the server first sent it otherwise),
// every session token and agent key becomes a `synthetic-*` placeholder, and each user id and
// pairing code becomes a fixed stand-in. Times and `confirm` tokens stay as the server sent them.

import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { createApp } from "../../src/app";
import { ensureAccount, type AccountSpec } from "../../src/auth/accounts";
import { createAuth, type Auth } from "../../src/auth/create-auth";
import { applyMigrations, type Queryable } from "../../src/db/migrations";
import type { AppDatabase } from "../../src/db/postgres";
import { schema as dbSchema } from "../../src/db/schema";
import type { QuestionMakerServices } from "../../src/routes/question-maker";

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export const SECRET = "test-secret-that-is-at-least-32-characters";
export const BASE = "http://localhost:4318";

/** The account every scenario signs in as, unless it says otherwise. */
export const STUDENT: AccountSpec = { email: "student@example.com", password: "synthetic-pass-1", name: "Sam Student", role: "student" };
export const ADMIN: AccountSpec = { email: "owner@example.com", password: "synthetic-admin-pass", name: "Owner", role: "admin" };

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;

/** A JSON value read from a response, which says where it came from when it is not what the scenario expects. */
export class Doc {
  readonly value: Json;
  readonly where: string;

  constructor(value: Json, where: string) {
    this.value = value;
    this.where = where;
  }

  #object(): Record<string, Json> {
    if (this.value === null || typeof this.value !== "object" || Array.isArray(this.value)) {
      throw new Error(`${this.where} is not an object: ${JSON.stringify(this.value).slice(0, 300)}`);
    }
    return this.value;
  }

  has(key: string): boolean {
    return key in this.#object();
  }

  /** A copy of the object, to send back changed. */
  fields(): Record<string, Json> {
    return { ...this.#object() };
  }

  get(key: string): Doc {
    const object = this.#object();
    if (!(key in object)) throw new Error(`${this.where} has no ${key}: ${JSON.stringify(object).slice(0, 300)}`);
    return new Doc(object[key] ?? null, `${this.where}.${key}`);
  }

  str(key?: string): string {
    const value = key === undefined ? this.value : this.get(key).value;
    if (typeof value !== "string") throw new Error(`${this.where}${key === undefined ? "" : `.${key}`} is not a string: ${JSON.stringify(value)}`);
    return value;
  }

  num(key?: string): number {
    const value = key === undefined ? this.value : this.get(key).value;
    if (typeof value !== "number") throw new Error(`${this.where}${key === undefined ? "" : `.${key}`} is not a number: ${JSON.stringify(value)}`);
    return value;
  }

  list(key?: string): Doc[] {
    const doc = key === undefined ? this : this.get(key);
    if (!Array.isArray(doc.value)) throw new Error(`${doc.where} is not a list: ${JSON.stringify(doc.value).slice(0, 300)}`);
    return doc.value.map((item, index) => new Doc(item, `${doc.where}[${String(index)}]`));
  }

  /** The item of `key` whose `field` is `value`. */
  find(key: string, field: string, value: string): Doc {
    const found = this.list(key).find((item) => item.get(field).value === value);
    if (!found) throw new Error(`${this.where}.${key} has no ${field} ${value}`);
    return found;
  }

  isNull(key: string): boolean {
    return this.get(key).value === null;
  }
}

/** Fails the recording with what the scenario expected. */
export function expect(condition: boolean, what: string, detail?: unknown): asserts condition {
  if (!condition) throw new Error(detail === undefined ? what : `${what}: ${JSON.stringify(detail).slice(0, 400)}`);
}

export interface Exchange {
  method: string;
  path: string;
  query: Record<string, string>;
  token: string | null;
  body: Json;
  status: number;
  headers: Record<string, string>;
  response: Json;
}

export interface CallInit {
  method?: string;
  json?: Json;
  query?: Record<string, string>;
  /** The bearer token to send. Left out, the world's signed-in session; null, none. */
  token?: string | null;
}

export interface BootOptions {
  /** False boots the app with sign-in not configured, as a server without a database or secret runs. */
  auth?: boolean;
  questionMaker?: (db: AppDatabase) => QuestionMakerServices;
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

export class World {
  readonly recorded = new Map<string, Exchange>();
  /** The signed-in session calls send unless they name another token. */
  token: string | null = null;
  readonly #names = new Map<string, string>();
  readonly #aliases = new Map<string, string>();
  readonly #serverIds: string[] = [];
  readonly #known = new Set<string>();
  #users = 0;
  #clientIds = 0;
  /** Numbers the ids this scenario's server made that no test names. */
  readonly scenario: number;
  readonly client: PGlite;
  readonly db: AppDatabase;
  readonly auth: Auth;
  readonly app: ReturnType<typeof createApp>;

  private constructor(scenario: number, client: PGlite, db: AppDatabase, auth: Auth, app: ReturnType<typeof createApp>) {
    this.scenario = scenario;
    this.client = client;
    this.db = db;
    this.auth = auth;
    this.app = app;
  }

  static async boot(scenario: number, options: BootOptions = {}): Promise<World> {
    const client = new PGlite();
    await applyMigrations(queryable(client));
    const db = drizzle(client, { schema: dbSchema }) as unknown as AppDatabase;
    const auth = createAuth({ db, secret: SECRET, baseURL: BASE });
    const questionMaker = options.questionMaker?.(db);
    const app = createApp({ version: "0000000", auth: options.auth === false ? undefined : { auth, db }, questionMaker });
    return new World(scenario, client, db, auth, app);
  }

  async close(): Promise<void> {
    await this.client.close();
  }

  /** Makes the account, as the server's own account setup does. */
  async create(spec: AccountSpec): Promise<void> {
    await ensureAccount(this.auth, spec);
  }

  /** Makes the account and signs it in, its token recorded as `placeholder`. */
  async account(spec: AccountSpec, placeholder: string): Promise<string> {
    await this.create(spec);
    return this.signIn(spec.email, spec.password, placeholder);
  }

  /** Signs in through the route and records its token as `placeholder`. Becomes the world's session when it has none. */
  async signIn(email: string, password: string, placeholder: string): Promise<string> {
    const signed = await this.ok("/api/sign-in/password", 200, { method: "POST", json: { email, password }, token: null });
    return this.session(signed, placeholder);
  }

  /** Takes the token and user of a sign-in, sign-up or password change, as `placeholder`. */
  session(signed: Doc, placeholder: string): string {
    const token = signed.str("token");
    this.alias(token, placeholder);
    this.user(signed.get("user").str("id"));
    this.token ??= token;
    return token;
  }

  /** Names a user id the server made, once. */
  user(id: string): void {
    if (this.#aliases.has(id)) return;
    this.#users += 1;
    this.alias(id, `synthetic-user-${String(this.#users)}`);
  }

  /** Writes `real`, wherever it appears in a recording, as `synthetic`. */
  alias(real: string, synthetic: string): void {
    const existing = this.#aliases.get(real);
    if (existing !== undefined && existing !== synthetic) throw new Error(`${real} is already written as ${existing}`);
    this.#aliases.set(real, synthetic);
  }

  /** Writes the id the server made as `synthetic`, the id a test names. */
  name(real: string, synthetic: string): void {
    expect(this.#known.has(real), `${synthetic} names an id the server never sent`, real);
    const existing = this.#names.get(real);
    if (existing !== undefined && existing !== synthetic) throw new Error(`${real} is already named ${existing}`);
    for (const [other, taken] of this.#names) {
      if (taken === synthetic && other !== real) throw new Error(`${synthetic} already names ${other}`);
    }
    this.#names.set(real, synthetic);
  }

  /** A new id of the client's own, such as an answer's clientAttemptId, numbered so a re-record sends the same ones. */
  clientId(): string {
    this.#clientIds += 1;
    return `c1000000-0000-4000-8000-${String(this.#clientIds).padStart(12, "0")}`;
  }

  async sql(statement: string, params: unknown[] = []): Promise<void> {
    await this.client.query(statement, params);
  }

  /** One call through the routes. Ids it sends that no response carried first are the client's own and stay as they are. */
  async call(path: string, init: CallInit = {}): Promise<Exchange> {
    const token = init.token === undefined ? this.token : init.token;
    const headers: Record<string, string> = {};
    if (token !== null) headers.authorization = `Bearer ${token}`;
    if (init.json !== undefined) headers["content-type"] = "application/json";
    const query = init.query ?? {};
    const search = new URLSearchParams(query).toString();
    const method = init.method ?? "GET";
    const body = init.json ?? null;
    this.#see(JSON.stringify([path, query, body]), false);
    const response = await this.app.request(search === "" ? path : `${path}?${search}`, {
      method,
      headers,
      body: init.json === undefined ? null : JSON.stringify(init.json),
    });
    const text = await response.text();
    const parsed = text.length > 0 ? (JSON.parse(text) as Json) : null;
    this.#see(text, true);
    const kept: Record<string, string> = {};
    const retryAfter = response.headers.get("retry-after");
    if (retryAfter !== null) kept["retry-after"] = retryAfter;
    return { method, path, query, token, body, status: response.status, headers: kept, response: parsed };
  }

  /** A call that must answer `status`, for setting a scenario up. */
  async ok(path: string, status: number, init: CallInit = {}): Promise<Doc> {
    const exchange = await this.call(path, init);
    const what = `${exchange.method} ${path}`;
    expect(exchange.status === status, `${what} answered ${String(exchange.status)}, not ${String(status)}`, exchange.response);
    return new Doc(exchange.response, what);
  }

  /** A call kept as the fixture `name`, which must answer `status`. */
  async record(name: string, path: string, status: number, init: CallInit = {}): Promise<Doc> {
    expect(!this.recorded.has(name), `${name} is recorded twice`);
    const exchange = await this.call(path, init);
    expect(exchange.status === status, `${name} answered ${String(exchange.status)}, not ${String(status)}`, exchange.response);
    this.recorded.set(name, exchange);
    return new Doc(exchange.response, name);
  }

  /** Registers the uuids in `text`: from a response they are the server's, from a request before any response they are the client's. */
  #see(text: string, fromServer: boolean): void {
    for (const match of text.matchAll(UUID)) {
      const id = match[0];
      if (this.#known.has(id)) continue;
      this.#known.add(id);
      if (fromServer) this.#serverIds.push(id);
    }
  }

  /** The recordings as fixture files, every rewrite applied. */
  fixtures(commit: string): Map<string, Json> {
    const names = new Map(this.#names);
    const taken = new Set(names.values());
    let next = 0;
    for (const id of this.#serverIds) {
      if (names.has(id)) continue;
      let synthetic: string;
      do {
        next += 1;
        synthetic = `00000000-0000-4000-8${String(this.scenario).padStart(3, "0")}-${String(next).padStart(12, "0")}`;
      } while (taken.has(synthetic));
      names.set(id, synthetic);
      taken.add(synthetic);
    }
    const aliases = [...this.#aliases].sort((a, b) => b[0].length - a[0].length);
    const rewrite = (text: string): string => {
      let out = text.replace(UUID, (id) => names.get(id) ?? id);
      for (const [real, synthetic] of aliases) out = out.split(real).join(synthetic);
      return out;
    };
    const deep = (value: Json): Json => {
      if (typeof value === "string") return rewrite(value);
      if (Array.isArray(value)) return value.map(deep);
      if (value !== null && typeof value === "object") {
        return Object.fromEntries(Object.entries(value).map(([key, inner]) => [rewrite(key), deep(inner)]));
      }
      return value;
    };
    const out = new Map<string, Json>();
    for (const [name, exchange] of this.recorded) {
      out.set(name, {
        recordedFrom: commit,
        request: {
          method: exchange.method,
          path: rewrite(exchange.path),
          query: deep(exchange.query),
          authorization: exchange.token === null ? null : `Bearer ${rewrite(exchange.token)}`,
          body: deep(exchange.body),
        },
        response: { status: exchange.status, headers: exchange.headers, body: deep(exchange.response) },
      });
    }
    return out;
  }
}
