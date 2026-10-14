import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parse } from "yaml";
import { LocalStore } from "../desktop/src/local-store.ts";
import { RemotePublisher, REMOTE_ORIGIN, REMOTE_ERROR, validateRemote, remoteCurl } from "../desktop/src/remote-share.ts";
import type { RemoteTransport } from "../desktop/src/remote-share.ts";
import { startDesktopServer } from "../desktop/src/server.ts";
import type { Profile, RemoteSubscription } from "../app/lib/types.ts";
import { UserError } from "../app/lib/errors.ts";

const remote: RemoteSubscription = { id: "a".repeat(32), manageKey: "b".repeat(64), downloadKey: "c".repeat(64), subscriptionUrl: `${REMOTE_ORIGIN}/remote-sub/${"a".repeat(32)}/${"c".repeat(64)}/sample.yaml`, updatedAt: 1000 };
const profile: Profile = { name: "增强-验收", sourceUrl: "https://example.com/source.yaml", groups: [{ name: "固定组", nodes: ["美国 S1"] }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "固定组" }] };
const source = (version = 1) => ({ config: { proxies: [{ name: "美国 S1", type: "ss", server: "1.1.1.1", port: 443, password: "fixture-node-password" }], rules: ["MATCH,DIRECT"], version }, fetchedAt: new Date().toISOString(), userInfo: "upload=0;total=100", sourceName: "验收" });
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "remote-share-test-"));
  const store = await new LocalStore(directory).load();
  const saved = await store.create(profile);
  return { directory, store, saved, close: () => rm(directory, { recursive: true, force: true }) };
}

test("remote publication is explicit, each sync fetches fresh original source, persists only descriptor", async () => {
  const instance = await fixture(); let fetched = 0; let update = 1000;
  const calls: { method: string; payload: Record<string, unknown>; key?: string }[] = [];
  const transport: RemoteTransport = async (method, _path, payload, key) => {
    calls.push({ method, payload: payload as Record<string, unknown>, key });
    return method === "POST" ? { ...remote, subscriptionPath: new URL(remote.subscriptionUrl).pathname } : { saved: true, updatedAt: ++update };
  };
  const publisher = new RemotePublisher(instance.store, { intervalMs: 0, transport, fetchSource: async () => source(++fetched) });
  try {
    assert.equal(await publisher.publish(instance.saved.id, instance.saved.manageKey), undefined);
    assert.equal(fetched, 0);
    const first = await publisher.publish(instance.saved.id, instance.saved.manageKey, true);
    assert.equal(first?.subscriptionUrl, remote.subscriptionUrl);
    assert.equal(calls[0].key, undefined);
    assert.equal(parse(String(calls[0].payload.sourceYaml)).version, 1);
    assert.deepEqual(parse(String(calls[0].payload.sourceYaml)).rules, ["MATCH,DIRECT"]);
    await publisher.publish(instance.saved.id, instance.saved.manageKey);
    assert.equal(fetched, 2); assert.equal(calls[1].method, "PUT"); assert.equal(calls[1].key, remote.manageKey);
    assert.equal(parse(String(calls[1].payload.sourceYaml)).version, 2);
    const restored = await new LocalStore(instance.directory).load();
    assert.equal((await restored.library()).current?.remote?.updatedAt, 1001);
    const disk = await readFile(join(instance.directory, "profiles.json"), "utf8");
    assert.ok(!disk.includes("fixture-node-password")); assert.ok(!disk.includes("sourceYaml"));
  } finally { await publisher.stop(); await instance.close(); }
});

test("per-profile queue serializes uploads and reloads latest profile, errors retain cloud descriptor without secret text", async () => {
  const instance = await fixture(); let release!: () => void; let started!: () => void;
  const startedPromise = new Promise<void>((resolve) => { started = resolve; });
  const hold = new Promise<void>((resolve) => { release = resolve; });
  const names: string[] = []; let call = 0;
  const publisher = new RemotePublisher(instance.store, { intervalMs: 0, fetchSource: async () => source(), transport: async (method, _path, payload) => {
    names.push((payload as { profile: Profile }).profile.name);
    if (++call === 1) { started(); await hold; }
    return method === "POST" ? { ...remote, subscriptionPath: new URL(remote.subscriptionUrl).pathname } : { saved: true, updatedAt: 2000 };
  } });
  try {
    const first = publisher.publish(instance.saved.id, instance.saved.manageKey, true); await startedPromise;
    await instance.store.update(instance.saved.id, instance.saved.manageKey, { ...profile, name: "增强-新名称" });
    const second = publisher.publish(instance.saved.id, instance.saved.manageKey); release(); await Promise.all([first, second]);
    assert.deepEqual(names, [profile.name, "增强-新名称"]);
    const broken = new RemotePublisher(instance.store, { intervalMs: 0, fetchSource: async () => { throw new Error("token=fixture-secret"); } });
    await assert.rejects(broken.publish(instance.saved.id, instance.saved.manageKey), { message: REMOTE_ERROR });
    assert.equal((await instance.store.library()).current?.remote?.lastError, REMOTE_ERROR);
    await broken.stop();
  } finally { release(); await publisher.stop(); await instance.close(); }
});

test("removing remote publication invalidates cloud record, preserves local URL and queued refresh cannot recreate it", async () => {
  const instance = await fixture(); await instance.store.setRemote(instance.saved.id, instance.saved.manageKey, remote);
  let deletes = 0, fetches = 0;
  const publisher = new RemotePublisher(instance.store, { intervalMs: 0, fetchSource: async () => { fetches++; return source(); }, transport: async (method) => { assert.equal(method, "DELETE"); deletes++; return { deleted: true }; } });
  try {
    await publisher.remove(instance.saved.id, instance.saved.manageKey);
    await publisher.publish(instance.saved.id, instance.saved.manageKey);
    const record = await instance.store.find(instance.saved.id, instance.saved.manageKey);
    assert.equal(record.remote, undefined); assert.equal(record.downloadKey, instance.saved.downloadKey);
    assert.equal(deletes, 1); assert.equal(fetches, 0);
  } finally { await publisher.stop(); await instance.close(); }
});

test("startup refresh touches only enabled records, stopping aborts active jobs and clears timer", async () => {
  const instance = await fixture(); let fetched = 0;
  const publisher = new RemotePublisher(instance.store, { intervalMs: 20, fetchSource: async (_url, signal) => {
    fetched++; return new Promise((_resolve, reject) => { signal.addEventListener("abort", () => reject(new Error("canceled")), { once: true }); });
  } });
  try {
    publisher.start(); await new Promise((resolve) => setTimeout(resolve, 30)); assert.equal(fetched, 0);
    await instance.store.setRemote(instance.saved.id, instance.saved.manageKey, remote);
    await new Promise((resolve) => setTimeout(resolve, 40)); assert.equal(fetched, 1);
    await publisher.stop(); await new Promise((resolve) => setTimeout(resolve, 40)); assert.equal(fetched, 1);
  } finally { await publisher.stop(); await instance.close(); }
});

test("remote descriptor rejects third-party hosts, credentials and malformed keys; curl rejects non-fixed paths before network", async () => {
  assert.deepEqual(validateRemote(remote), remote);
  for (const value of [{ ...remote, subscriptionUrl: remote.subscriptionUrl.replace(REMOTE_ORIGIN, "https://evil.example") }, { ...remote, manageKey: remote.downloadKey }, { ...remote, updatedAt: NaN }, { ...remote, subscriptionUrl: `${remote.subscriptionUrl}?token=secret` }]) assert.throws(() => validateRemote(value));
  assert.equal(validateRemote({ ...remote, lastError: "token=fixture-secret" }).lastError, REMOTE_ERROR);
  await assert.rejects(remoteCurl("POST", "/api/inspect", {}, undefined, new AbortController().signal));
  await assert.rejects(remoteCurl("POST", "/api/remote-subscriptions", { big: "x".repeat(1_572_865) }, undefined, new AbortController().signal), { status: 413 });
});

test("local remote routes require session and edit key; failed remote upload still allows local save", async () => {
  const instance = await fixture(); await writeFile(join(instance.directory, "index.html"), "<html>fixture</html>");
  let failure = false;
  const running = await startDesktopServer({ port: 0, store: instance.store, assets: instance.directory, fetchSource: async () => source(), remote: { intervalMs: 0, transport: async (method) => {
    if (failure) throw new UserError("source credentials must not leak", 502);
    return method === "POST" ? { ...remote, subscriptionPath: new URL(remote.subscriptionUrl).pathname } : { saved: true, updatedAt: 2000 };
  } } });
  const origin = `http://127.0.0.1:${running.port}`;
  const cookie = (await fetch(origin)).headers.get("set-cookie")!.split(";")[0];
  const mutate = (path: string, method: string, data: unknown, key = instance.saved.manageKey) => fetch(`${origin}${path}`, { method, headers: { Origin: origin, Cookie: cookie, Authorization: `Bearer ${key}`, "Content-Type": "application/json" }, ...(method === "DELETE" ? {} : { body: JSON.stringify(data) }) });
  const path = `/api/profiles/${instance.saved.id}`;
  try {
    assert.equal((await fetch(`${origin}${path}/remote`, { method: "POST", headers: { Origin: origin, "Content-Type": "application/json", Authorization: `Bearer ${instance.saved.manageKey}` }, body: "{}" })).status, 401);
    assert.equal((await mutate(`${path}/remote`, "POST", {}, instance.saved.downloadKey)).status, 404);
    assert.equal((await mutate(`${path}/remote`, "POST", {})).status, 200);
    assert.equal((await mutate(path, "DELETE", null)).status, 409);
    failure = true;
    const saved = await mutate(path, "PUT", { ...profile, name: "增强-本机修改" });
    assert.equal(saved.status, 200); assert.equal(((await saved.json()) as { remote: RemoteSubscription }).remote.lastError, REMOTE_ERROR);
    assert.equal((await instance.store.find(instance.saved.id, instance.saved.manageKey)).profile.name, "增强-本机修改");
    failure = false; assert.equal((await mutate(`${path}/remote`, "DELETE", null)).status, 200);
    assert.equal((await mutate(path, "DELETE", null)).status, 200);
  } finally { await running.publisher.stop(); running.server.closeAllConnections(); await new Promise<void>((resolve) => running.server.close(() => resolve())); await instance.close(); }
});
