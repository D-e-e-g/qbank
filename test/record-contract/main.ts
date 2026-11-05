// Records every QBankKit contract fixture live against the server this directory is copied into.
//
// test/record-contract.sh copies this directory to apps/api/scripts in a scratch checkout and
// runs it with that package's tsx. The imports are the server's own source; they do not resolve
// from the iPhone repository. Each scenario boots its own throwaway server over an in-memory
// database, signs in with invented accounts, drives the real routes (Make questions and exam
// twins with the server's fake model), and keeps the exchanges it names. Every fixture is written
// stamped with the commit, openapi.json is copied, and pin.json names the commit. It does not
// fetch or modify the checkout, and it fails when a fixture in the directory has no scenario.

import { copyFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { recordAccountDeletion } from "./account";
import { recordAgents } from "./agents";
import { recordDeletion } from "./deletion";
import { recordMakeQuestions } from "./make-questions";
import { recordOrganizing } from "./organize";
import { recordPractice } from "./practice";
import { recordSessions } from "./session";
import { recordTopics } from "./topics";
import { recordTwins } from "./twins";
import type { Json, World } from "./world";

// The API image published for a commit, the same digest the web app's pin records.
// A newer checkout has no digest here; set QBANK_API_IMAGE for that re-pin.
const IMAGES: Record<string, string> = {
  d0db2444f2c236c3591aab3d9a0532631385ff85: "ghcr.io/d-e-e-g/nclex-qbank-api@sha256:1b96e033f30450ce38b951cd77704a7b9afe0f216b8e50a554720b56ba4513bf",
  "6b807f891e952f9dc3483c0f8b10ca032cd22983": "ghcr.io/d-e-e-g/nclex-qbank-api@sha256:dce87fedb83d25371c9aad8d2f3ae2dd72159cb230ea2c2b0e5b13f17a872060",
  c033890813f6a2c76a23688d2cf457fdd0ae7d62: "ghcr.io/d-e-e-g/nclex-qbank-api@sha256:5604fbb1ea804c87de595cd556a01ec224ad34a0557d99c34c64c741e7c44961",
  f4b1bb4033ad15b09619ad1c885e9eeb071a1c4f: "ghcr.io/d-e-e-g/nclex-qbank-api@sha256:69f9859a78e7473d5b082e70005024bd9c9cb1dd049e4082979163cb34eeb5ee",
  "9d2e5a265972afbc9495ebc682250b3418e8e9e7": "ghcr.io/d-e-e-g/nclex-qbank-api@sha256:8f67dec72ed330427d62e7c8b236cad88791b65a0173ca9e77212c229b0927bb",
};

const SCENARIOS: (() => Promise<World[]>)[] = [recordSessions, recordAccountDeletion, recordAgents, recordPractice, recordOrganizing, recordDeletion, recordTopics, recordMakeQuestions, recordTwins];

const [commit, fixturesDir, openapiPath] = process.argv.slice(2);
if (commit === undefined || fixturesDir === undefined || openapiPath === undefined || !/^[0-9a-f]{40}$/.test(commit)) {
  throw new Error("usage: main.ts <full-commit> <Fixtures-dir> <openapi.json>");
}
const image = process.env.QBANK_API_IMAGE ?? IMAGES[commit];
if (image === undefined || image === "") throw new Error(`No API image for ${commit}. Set QBANK_API_IMAGE to the image built from it.`);

const recorded = new Map<string, Json>();
for (const scenario of SCENARIOS) {
  for (const world of await scenario()) {
    for (const [name, fixture] of world.fixtures(commit)) {
      if (recorded.has(name)) throw new Error(`${name} is recorded by two scenarios`);
      recorded.set(name, fixture);
    }
  }
}

const contractDir = join(fixturesDir, "contract");
const unrecorded = readdirSync(contractDir)
  .filter((file) => file.endsWith(".json"))
  .map((file) => file.slice(0, -".json".length))
  .filter((name) => !recorded.has(name));
for (const [name, fixture] of recorded) {
  writeFileSync(join(contractDir, `${name}.json`), `${JSON.stringify(fixture, null, 2)}\n`);
}
copyFileSync(openapiPath, join(fixturesDir, "openapi.json"));
writeFileSync(join(fixturesDir, "pin.json"), `${JSON.stringify({ repository: "D-e-e-g/qbank-server", commit, path: "apps/api/openapi.json", image }, null, 2)}\n`);
console.log(`recorded ${String(recorded.size)} fixtures live at ${commit}`);
if (unrecorded.length > 0) {
  throw new Error(`No scenario records these fixtures: ${unrecorded.join(", ")}`);
}
