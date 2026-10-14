import type { Profile } from "../app/lib/types.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const directory = mkdtempSync(join(tmpdir(), "cc-server-test-"));
process.env.DATABASE_PATH = join(directory, "state.sqlite");
const { createRemoteCache, findRemoteCache, updateRemoteCache, deleteRemoteCache } = await import("../app/lib/remote-store.ts");
const { publicFetch } = await import("../server/public-fetch.ts");
const profile: Profile = { name: "增强-测试", sourceUrl: "https://example.com/sub", groups: [{ name: "Claude", nodes: ["US test"] }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude" }] };

test("SQLite persists remote records with independent hashed permissions", async () => {
  const cache = { profile, sourceYaml: "proxies:\n  - {name: US test, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: test}\nrules: []\n", sourceFetchedAt: "2026-10-14T00:00:00.000Z" };
  const created = await createRemoteCache(cache);
  assert.notEqual(created.manageKey, created.downloadKey);
  assert.equal((await findRemoteCache(created.id, created.downloadKey, true)).cache.profile.name, profile.name);
  await assert.rejects(findRemoteCache(created.id, created.downloadKey));
  await updateRemoteCache(created.id, created.manageKey, { ...cache, profile: { ...profile, name: "改名" } });
  assert.equal((await findRemoteCache(created.id, created.manageKey)).cache.profile.name, "改名");
  assert.equal(statSync(process.env.DATABASE_PATH!).mode & 0o777, 0o600);
  await deleteRemoteCache(created.id, created.manageKey);
  await assert.rejects(findRemoteCache(created.id, created.downloadKey, true));
});
test("server HTTP transport rejects local and cloud metadata addresses", async () => {
  for (const url of ["http://127.0.0.1/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/"]) await assert.rejects(publicFetch(url));
});
process.on("exit", () => rmSync(directory, { recursive: true, force: true }));

test("every standard download refreshes source, then uses isolated original cache on outage", async () => {
  const { fetchProfileSource } = await import("../server/source-cache.ts");
  const { parseSource } = await import("../app/lib/source.ts");
  const { transformSource } = await import("../app/lib/profile.ts");
  let calls = 0;
  const config = parseSource("proxies:\n  - {name: US test, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: test}\nrules: []\n");
  const live = async () => { calls++; return { config, fetchedAt: "2026-10-14T00:00:00.000Z", sourceName: "source", userInfo: undefined }; };
  assert.equal((await fetchProfileSource("cache-test", profile, live)).mode, "live");
  assert.equal((await fetchProfileSource("cache-test", profile, live)).mode, "live");
  assert.equal(calls, 2);
  const outage = async () => { throw new Error("source down"); };
  const cached = await fetchProfileSource("cache-test", profile, outage);
  assert.equal(cached.mode, "cache");
  const changed = { ...profile, rules: [{ type: "DOMAIN" as const, value: "api.anthropic.com", group: "Claude" }] };
  assert.match(transformSource(cached.config, changed).yaml, /DOMAIN,api.anthropic.com,Claude/);
  await assert.rejects(fetchProfileSource("cache-test", { ...profile, sourceUrl: "https://different.example/sub" }, outage));
});
