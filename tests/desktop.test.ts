import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer, request as httpRequest } from "node:http";
import { LocalStore } from "../desktop/src/local-store.ts";
import { startDesktopServer } from "../desktop/src/server.ts";
import { curlFetch } from "../desktop/src/local-source.ts";
import { UserError } from "../app/lib/errors.ts";
import type { Profile, SavedProfile } from "../app/lib/types.ts";
import type { SourceConfig } from "../app/lib/source.ts";

const sessions = new Map<string, string>();
async function testFetch(input: string, init: RequestInit = {}) {
  const url = new URL(input);
  const headers = new Headers(init.headers);
  const cookie = sessions.get(url.origin);
  if (url.pathname.startsWith("/api/") && cookie) headers.set("Cookie", cookie);
  return fetch(input, { ...init, headers });
}

const profile: Profile = { name: "增强-测试订阅", sourceUrl: "https://example.com/source.yaml", groups: [{ name: "Claude 固定节点", nodes: ["美国 S1"] }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude 固定节点" }] };
const config = (node = "美国 S1"): SourceConfig => ({ proxies: [{ name: node, type: "ss", server: "1.1.1.1", port: 443 }], "proxy-groups": [{ name: "源代理组", type: "select", proxies: [node] }], rules: ["MATCH,源代理组"] });

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "desktop-backend-test-"));
  const store = await new LocalStore(join(directory, "state")).load();
  await writeFile(join(directory, "index.html"), "<!doctype html><h1>Desktop</h1>");
  let count = 0;
  let missing = false;
  let fail = false;
  const running = await startDesktopServer({ port: 0, store, assets: directory, fetchSource: async () => {
    count++;
    if (fail) throw new UserError("源订阅请求失败。", 502);
    return { config: config(missing ? "美国 S2" : "美国 S1"), fetchedAt: new Date().toISOString(), userInfo: "upload=0;download=1;total=100", sourceName: "测试订阅" };
  } });
  const origin = `http://127.0.0.1:${running.port}`;
  const rootPage = await fetch(`${origin}/`);
  const session = rootPage.headers.get("set-cookie")?.split(";")[0];
  assert.ok(session);
  sessions.set(origin, session);
  return { ...running, origin, directory, calls: () => count, missing: () => { missing = true; }, fail: () => { fail = true; }, close: async () => {
    sessions.delete(origin);
    running.server.closeAllConnections();
    await new Promise<void>((resolve) => running.server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  } };
}

async function mutate(origin: string, path: string, value: unknown, method = "POST", key?: string) {
  return testFetch(`${origin}${path}`, { method, headers: { Origin: origin, "Content-Type": "application/json", ...(key ? { Authorization: `Bearer ${key}` } : {}) }, body: method === "DELETE" ? undefined : JSON.stringify(value) });
}

test("desktop persists incomplete draft, saved keys and library across restart with private permissions", async () => {
  const instance = await fixture();
  try {
    const empty = { ...profile, sourceUrl: "", groups: [{ name: "Claude 固定节点", nodes: [] }] };
    const response = await mutate(instance.origin, "/api/desktop/draft", { profile: empty, current: null }, "PUT");
    assert.equal(response.status, 200);
    assert.equal(instance.calls(), 0);
    const createdResponse = await mutate(instance.origin, "/api/profiles", profile);
    assert.equal(createdResponse.status, 201);
    const saved = await createdResponse.json() as SavedProfile;
    assert.notEqual(saved.manageKey, saved.downloadKey);
    await mutate(instance.origin, "/api/desktop/draft", { profile: { ...profile, sourceUrl: "https://example.com/new.yaml" }, current: saved }, "PUT");
    const reopened = await new LocalStore(join(instance.directory, "state")).load();
    const library = await reopened.library();
    assert.equal(library.profiles.length, 1);
    assert.equal(library.profiles[0].name, profile.name);
    assert.equal(library.current?.id, saved.id);
    assert.equal(library.draft?.sourceUrl, "https://example.com/new.yaml");
    assert.equal((await stat(join(instance.directory, "state"))).mode & 0o777, 0o700);
    assert.equal((await stat(join(instance.directory, "state", "profiles.json"))).mode & 0o777, 0o600);
    const disk = await readFile(join(instance.directory, "state", "profiles.json"), "utf8");
    assert.ok(!disk.includes('"proxies"'));
    assert.ok(!disk.includes('"yaml"'));
    const newDraft = await mutate(instance.origin, "/api/desktop/draft", { profile: empty, current: null }, "PUT");
    assert.equal(newDraft.status, 200);
    assert.equal((await instance.store.library()).current, null);
  } finally { await instance.close(); }
});

test("every subscription request fetches live source, old filename works, failure never returns stale content", async () => {
  const instance = await fixture();
  try {
    const saved = await (await mutate(instance.origin, "/api/profiles", profile)).json() as SavedProfile;
    assert.equal(instance.calls(), 1);
    const first = await testFetch(`${instance.origin}${saved.subscriptionPath}`);
    assert.equal(first.status, 200);
    assert.match(await first.text(), /DOMAIN-SUFFIX,claude.ai,Claude 固定节点/);
    assert.equal(first.headers.get("subscription-userinfo"), "upload=0;download=1;total=100");
    assert.match(first.headers.get("content-disposition") ?? "", /filename\*=UTF-8''/);
    assert.match(first.headers.get("cache-control") ?? "", /no-store/);
    await fetch(`${instance.origin}/sub/${saved.id}/${saved.downloadKey}`);
    assert.equal(instance.calls(), 3);
    const rename = await mutate(instance.origin, `/api/profiles/${saved.id}`, { ...profile, name: "增强-改名" }, "PUT", saved.manageKey);
    assert.equal(rename.status, 200);
    assert.equal((await testFetch(`${instance.origin}${saved.subscriptionPath}`)).status, 200);
    instance.missing();
    const rejected = await testFetch(`${instance.origin}${saved.subscriptionPath}`);
    assert.equal(rejected.status, 200);
    assert.match(await rejected.text(), /REJECT/);
    instance.fail();
    const failure = await testFetch(`${instance.origin}${saved.subscriptionPath}`);
    assert.equal(failure.status, 502);
    assert.deepEqual(await failure.json(), { error: "源订阅请求失败。" });
  } finally { await instance.close(); }
});

test("download keys never grant edit permissions and invalid keys are rejected before network fetch", async () => {
  const instance = await fixture();
  try {
    const saved = await (await mutate(instance.origin, "/api/profiles", profile)).json() as SavedProfile;
    const response = await mutate(instance.origin, `/api/profiles/${saved.id}`, profile, "PUT", saved.downloadKey);
    assert.equal(response.status, 404);
    assert.equal(instance.calls(), 1);
    assert.equal((await testFetch(`${instance.origin}/sub/${saved.id}/${saved.manageKey}`)).status, 404);
    assert.equal(instance.calls(), 1);
    const wrongDraft = await mutate(instance.origin, "/api/desktop/draft", { profile, current: { ...saved, manageKey: saved.downloadKey } }, "PUT");
    assert.equal(wrongDraft.status, 401);
    assert.equal((await mutate(instance.origin, `/api/profiles/${saved.id}`, null, "DELETE", saved.manageKey)).status, 200);
    assert.equal((await instance.store.library()).current, null);
  } finally { await instance.close(); }
});

test("cross-site requests, forged hosts, invalid JSON and oversized payloads fail closed", async () => {
  const instance = await fixture();
  try {
    assert.equal((await testFetch(`${instance.origin}/api/desktop`, { headers: { Origin: "https://evil.example" } })).status, 403);
    assert.equal(await new Promise<number>((resolve, reject) => { const request = httpRequest(`${instance.origin}/api/desktop`, { headers: { Host: "evil.example" } }, (response) => { response.resume(); resolve(response.statusCode ?? 0); }); request.on("error", reject); request.end(); }), 403);
    assert.equal((await testFetch(`${instance.origin}/api/desktop`, { headers: { "Sec-Fetch-Site": "cross-site" } })).status, 403);
    assert.equal((await testFetch(`${instance.origin}/api/profiles`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(profile) })).status, 403);
    assert.equal((await testFetch(`${instance.origin}/api/profiles`, { method: "POST", headers: { Origin: instance.origin, "Content-Type": "text/plain" }, body: JSON.stringify(profile) })).status, 415);
    assert.equal((await testFetch(`${instance.origin}/api/profiles`, { method: "POST", headers: { Origin: instance.origin, "Content-Type": "application/json" }, body: "invalid" })).status, 400);
    assert.equal((await mutate(instance.origin, "/api/desktop/draft", { value: "x".repeat(70_000) }, "PUT")).status, 413);
    assert.equal((await fetch(`${instance.origin}/api/desktop`)).status, 401);
    assert.equal(instance.calls(), 0);
  } finally { await instance.close(); }
});

test("static assets reject encoded traversal and symlink escapes", async () => {
  const instance = await fixture();
  const outside = await mkdtemp(join(tmpdir(), "desktop-outside-test-"));
  try {
    await writeFile(join(outside, "secret.txt"), "private");
    await symlink(join(outside, "secret.txt"), join(instance.directory, "leak.txt"));
    assert.equal((await testFetch(`${instance.origin}/`)).status, 200);
    assert.equal((await testFetch(`${instance.origin}/%2e%2e%2fsecret.txt`)).status, 404);
    assert.equal((await testFetch(`${instance.origin}/leak.txt`)).status, 404);
    assert.equal((await testFetch(`${instance.origin}/%00`)).status, 404);
  } finally { await instance.close(); await rm(outside, { recursive: true, force: true }); }
});

test("system curl ignores user curlrc, preserves raw headers, does not follow redirects or attach cookies", async () => {
  const requests: { cookie?: string; auth?: string; ua?: string; path?: string }[] = [];
  const server = createServer((request, response) => {
    requests.push({ cookie: request.headers.cookie, auth: request.headers.authorization, ua: request.headers["user-agent"], path: request.url });
    if (request.url?.startsWith("/redirect")) { response.writeHead(302, { Location: "/target" }); response.end(); return; }
    response.writeHead(200, { "Content-Disposition": "attachment; filename=source.yaml", "Subscription-Userinfo": "upload=0;total=100" }); response.end("proxies: []");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const origin = `http://127.0.0.1:${address.port}`;
  try {
    const response = await curlFetch(`${origin}/source?token=private`, { headers: { "User-Agent": "clash.meta/subscription-enhancer" } });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-disposition"), "attachment; filename=source.yaml");
    assert.equal(await response.text(), "proxies: []");
    const redirect = await curlFetch(`${origin}/redirect`);
    assert.equal(redirect.status, 302);
    assert.equal(redirect.headers.get("location"), "/target");
    assert.equal(requests.length, 2);
    assert.equal(requests[0].cookie, undefined);
    assert.equal(requests[0].auth, undefined);
    assert.equal(requests[0].ua, "clash.meta/subscription-enhancer");
  } finally { server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve())); }
});
