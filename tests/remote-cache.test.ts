import test from "node:test";
import assert from "node:assert/strict";
import { parse } from "yaml";
import { MAX_REMOTE_SOURCE, remoteDownload, remoteSubscriptionPath, renderRemoteSubscription, validateRemoteCache, validateRemoteIdentity } from "../app/lib/remote-cache.ts";
import { UserError } from "../app/lib/errors.ts";
import { parseSource } from "../app/lib/source.ts";
import type { Profile } from "../app/lib/types.ts";

const profile: Profile = { name: "增强-远程测试", sourceUrl: "https://example.com/config.yaml", groups: [{ name: "Claude 固定", nodes: ["Exit"], chain: { entry: "Entry" } }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude 固定" }] };
const yaml = `proxies:
  - { name: Entry, type: ss, server: entry.example.com, port: 443, cipher: aes-128-gcm, password: original-entry }
  - { name: Exit, type: ss, server: exit.example.com, port: 443, cipher: aes-128-gcm, password: original-exit }
proxy-groups:
  - { name: Original, type: select, proxies: [Exit] }
rules:
  - MATCH,Original
`;
const input = () => ({ profile: structuredClone(profile), sourceYaml: yaml, sourceFetchedAt: "2026-01-01T00:00:00.000Z", userInfo: "upload=0;download=1;total=100" });
const offline = async () => { throw new Error("Cloud source blocked"); };

test("validates bounded original snapshot without storing or replacing it with enhanced YAML", () => {
  const cache = validateRemoteCache(input());
  assert.equal(cache.sourceYaml, yaml);
  assert.equal(cache.sourceFetchedAt, "2026-01-01T00:00:00.000Z");
  assert.equal(cache.profile.groups[0].chain?.entry, "Entry");
  assert.ok(!cache.sourceYaml.includes("链式出口"));
  assert.ok(!cache.sourceYaml.includes("DOMAIN-SUFFIX,claude.ai"));
  assert.equal(validateRemoteCache({ ...input(), sourceFetchedAt: "2026-01-01T00:00:00Z" }).sourceFetchedAt, cache.sourceFetchedAt);
});

test("bad YAML, private source URLs, excessive snapshots, headers and timestamps fail before persistence", () => {
  assert.throws(() => validateRemoteCache(null));
  assert.throws(() => validateRemoteCache({ ...input(), sourceYaml: "Base64-unknown" }));
  assert.throws(() => validateRemoteCache({ ...input(), sourceYaml: "proxies: [" }));
  assert.throws(() => validateRemoteCache({ ...input(), sourceYaml: "x".repeat(MAX_REMOTE_SOURCE + 1) }), (error: unknown) => error instanceof UserError && error.status === 413);
  assert.throws(() => validateRemoteCache({ ...input(), profile: { ...profile, sourceUrl: "http://127.0.0.1/source" } }));
  assert.throws(() => validateRemoteCache({ ...input(), userInfo: "download=1\r\nAuthorization: secret" }));
  assert.throws(() => validateRemoteCache({ ...input(), sourceFetchedAt: "invalid" }));
  assert.throws(() => validateRemoteCache({ ...input(), sourceFetchedAt: "2026-02-31T00:00:00Z" }));
  const huge = { ...profile, rules: [], groups: Array.from({ length: 10 }, (_, index) => ({ name: `Group ${index}`, nodes: Array.from({ length: 100 }, (_, node) => `${index}-${node}-${"x".repeat(180)}`) })) };
  assert.throws(() => validateRemoteCache({ ...input(), profile: huge }), (error: unknown) => error instanceof UserError && error.status === 413);
});

test("each GET fetches live source and applies the current profile, headers disclose actual source timestamp", async () => {
  const cache = validateRemoteCache(input());
  let calls = 0;
  const live = async () => {
    calls++;
    return { config: parseSource(yaml.replace("original-exit", `live-exit-${calls}`)), fetchedAt: `2026-01-02T00:00:0${calls}.000Z`, userInfo: "upload=0;download=2;total=100" };
  };
  const first = await renderRemoteSubscription(cache, { fetchLive: live });
  assert.equal(first.headers.get("X-Subscription-Source"), "live");
  assert.equal(Buffer.from(first.headers.get("Profile-Title")!.slice(7), "base64").toString("utf8"), cache.profile.name);
  assert.equal(first.headers.get("X-Source-Updated-At"), "2026-01-02T00:00:01.000Z");
  assert.equal(first.headers.get("Subscription-Userinfo"), "upload=0;download=2;total=100");
  assert.match(first.headers.get("Cache-Control") ?? "", /no-store/);
  assert.match(first.headers.get("Content-Disposition") ?? "", /filename\*=UTF-8''/);
  assert.match(await first.text(), /live-exit-1/);
  cache.profile.rules = [{ type: "DOMAIN-SUFFIX", value: "anthropic.com", group: "Claude 固定" }];
  const second = await renderRemoteSubscription(cache, { fetchLive: live });
  const secondYaml = await second.text();
  assert.match(secondYaml, /live-exit-2/);
  assert.match(secondYaml, /DOMAIN-SUFFIX,anthropic.com,Claude 固定/);
  assert.equal(calls, 2);
  assert.equal(cache.sourceYaml, yaml);
});

test("failed live fetch uses cached SOURCE and reapplies chain and rule edits at request time", async () => {
  const cache = validateRemoteCache(input());
  const first = await renderRemoteSubscription(cache, { fetchLive: offline });
  assert.equal(first.headers.get("X-Subscription-Source"), "cache");
  assert.equal(first.headers.get("X-Source-Updated-At"), cache.sourceFetchedAt);
  const original = parse(await first.text());
  assert.equal(original.proxies[1]["dialer-proxy"], undefined);
  assert.equal(original.proxies[2]["dialer-proxy"], "Entry");
  assert.equal(original.proxies[2].password, "original-exit");
  cache.profile.groups[0].chain = undefined;
  cache.profile.rules[0].value = "anthropic.com";
  const second = await renderRemoteSubscription(cache, { fetchLive: offline });
  const edited = parse(await second.text());
  assert.equal(edited.proxies.length, 2);
  assert.equal(edited["proxy-groups"][1].proxies[0], "Exit");
  assert.equal(edited.rules[0], "DOMAIN-SUFFIX,anthropic.com,Claude 固定");
  assert.equal(cache.sourceYaml, yaml);
});

test("missing current nodes reject routes even if the backup still has those nodes", async () => {
  const cache = validateRemoteCache(input());
  const response = await renderRemoteSubscription(cache, { fetchLive: async () => ({ config: parseSource("proxies: [{name: New, type: ss}]"), fetchedAt: "2026-01-02T00:00:00Z" }) });
  const output = parse(await response.text());
  assert.deepEqual(output["proxy-groups"][0].proxies, ["REJECT"]);
  assert.equal(response.headers.get("X-Subscription-Source"), "live");
  assert.equal(response.headers.get("X-Subscription-Warnings"), "1");
});

test("live transform errors never silently restore old routes from the backup", async () => {
  const cache = validateRemoteCache(input());
  const conflicting = `${yaml}\n` .replace("name: Original", "name: Claude 固定");
  await assert.rejects(renderRemoteSubscription(cache, { fetchLive: async () => ({ config: parseSource(conflicting), fetchedAt: "2026-01-02T00:00:00Z" }) }), /重名/);
  await assert.rejects(renderRemoteSubscription({ ...cache, sourceYaml: "invalid" }, { fetchLive: offline }));
});

test("live deadline aborts the request and returns the authorized backup without waiting indefinitely", async () => {
  const cache = validateRemoteCache(input());
  let canceled = false;
  const started = Date.now();
  const response = await renderRemoteSubscription(cache, { timeoutMs: 20, fetchLive: async (_url, signal) => new Promise((_accept, reject) => {
    signal.addEventListener("abort", () => { canceled = true; reject(new Error("aborted")); }, { once: true });
  }) });
  assert.ok(canceled);
  assert.ok(Date.now() - started < 500);
  assert.equal(response.headers.get("X-Subscription-Source"), "cache");
});

test("invalid or unauthorized download keys fail before any cache content or source network activity", async () => {
  const id = "a".repeat(32), editKey = "b".repeat(64), downloadKey = "c".repeat(64);
  let lookups = 0, fetches = 0;
  const find = async (_id: string, key: string) => {
    lookups++;
    if (key !== downloadKey) throw new UserError("remote auth failed", 404);
    return validateRemoteCache(input());
  };
  const fetchLive = async () => { fetches++; throw new Error("offline"); };
  await assert.rejects(remoteDownload(id, editKey, find, { fetchLive }));
  assert.equal(fetches, 0);
  assert.equal(lookups, 1);
  await assert.rejects(remoteDownload(id, "invalid", find, { fetchLive }));
  assert.equal(lookups, 1);
  assert.equal(fetches, 0);
  assert.equal((await remoteDownload(id, downloadKey, find, { fetchLive })).status, 200);
  assert.equal(fetches, 1);
  assert.throws(() => validateRemoteIdentity("invalid", downloadKey));
  assert.equal(remoteSubscriptionPath("增强-原名", id, downloadKey), `/remote-sub/${id}/${downloadKey}/${encodeURIComponent("增强-原名.yaml")}`);
});
