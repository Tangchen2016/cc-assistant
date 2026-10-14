import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, chmod, readFile, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { parse } from "yaml";
import { DELAY_TARGET, isolatedDelayConfig, pingNodeDelay, prepareDelayNodes, safeDelayNode, cancelNodeDelays } from "../desktop/src/node-delay.ts";
import type { SourceConfig } from "../app/lib/source.ts";

type Node = SourceConfig["proxies"][number];
const node = (name = "美国 S1", options: Record<string, unknown> = {}): Node => ({ name, type: "http", server: "1.1.1.1", port: 443, ...options });
const config = (...nodes: Node[]): SourceConfig => ({ proxies: nodes, tun: { enable: true }, dns: { enable: true, listen: "0.0.0.0:53" }, "external-controller": "0.0.0.0:9090", "proxy-providers": { unsafe: { path: "/etc/hosts" } }, rules: ["MATCH,DIRECT"] });
const resolve = async () => ["1.1.1.1"];

async function fakeEngine() {
  const root = await mkdtemp("/tmp/studio-engine-test-");
  const log = join(root, "receipt.json");
  const binary = join(root, "engine");
  const script = `#!${process.execPath}
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const file = process.argv[process.argv.indexOf('-f') + 1];
const text = fs.readFileSync(file, 'utf8');
const socket = /^external-controller-unix: (.+)$/m.exec(text)[1].replace(/^"|"$/g, '');
const receipt = { config: text, pid: process.pid, env: Object.keys(process.env), calls: [], maxConcurrent: 0, dirMode: fs.statSync(path.dirname(file)).mode & 511, fileMode: fs.statSync(file).mode & 511 };
const save = () => fs.writeFileSync(${JSON.stringify(log)}, JSON.stringify(receipt), {mode: 384});
let active = 0;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  receipt.calls.push(url.pathname + url.search); save();
  if (url.pathname === '/version') {res.setHeader('Content-Type', 'application/json');res.end(JSON.stringify({version:'1.19.24'}));return;}
  const match = /^\\/proxies\\/(.*?)(\\/delay)?$/.exec(url.pathname);
  if (!match) {res.writeHead(404);res.end('{}');return;}
  const name = decodeURIComponent(match[1]);
  if (match[2]) {
    if (name === 'Slow') return;
    active++; receipt.maxConcurrent = Math.max(receipt.maxConcurrent, active); save();
    setTimeout(() => {
      active--; res.writeHead(name === 'Timeout' ? 504 : name === 'Failed' ? 503 : 200, {'Content-Type':'application/json'});
      res.end(JSON.stringify({delay: name === 'Zero' ? 0 : 120}));
    }, 80);
  } else {
    res.setHeader('Content-Type','application/json');
    res.end(JSON.stringify({extra:{[${JSON.stringify(DELAY_TARGET)}]:{alive:name !== 'WrongStatus',history:[{delay:name === 'WrongStatus' ? 0 : 120}]}}}));
  }
});
server.listen(socket, save);
process.on('SIGTERM', () => {server.closeAllConnections();server.close(()=>process.exit(0));});
`;
  await writeFile(binary, script, { mode: 0o700 });
  await chmod(binary, 0o700);
  return { root, binary, log, close: () => rm(root, { recursive: true, force: true }) };
}

async function eventually(receipt: string) {
  for (let count = 0; count < 50; count++) {
    try { return JSON.parse(await readFile(receipt, "utf8")) as { pid: number; config: string; env: string[]; calls: string[]; maxConcurrent: number; dirMode: number; fileMode: number }; }
    catch { await new Promise((resolve) => setTimeout(resolve, 20)); }
  }
  throw new Error("engine did not start");
}

function isDead(pid: number) { try { process.kill(pid, 0); return false; } catch { return true; } }

test("isolated config excludes all source runtime state and credentials never enter argv or inherited env", async () => {
  const engine = await fakeEngine();
  const previous = process.env.CLASH_POST_UP;
  process.env.CLASH_POST_UP = "must-not-run";
  try {
    const result = await pingNodeDelay(config(node()), ["美国 S1"], { binaryPath: engine.binary, tempRoot: engine.root, resolve });
    assert.equal(result.method, "https");
    assert.equal(result.target, DELAY_TARGET);
    assert.deepEqual(result.results, [{ name: "美国 S1", status: "ok", latencyMs: 120 }]);
    const receipt = await eventually(engine.log);
    const isolated = parse(receipt.config);
    assert.equal(isolated.tun.enable, false);
    assert.equal(isolated.dns.enable, false);
    assert.equal(isolated["proxy-providers"], undefined);
    assert.equal(isolated["external-controller"], "");
    assert.deepEqual(isolated.rules, ["MATCH,REJECT"]);
    assert.equal(isolated.port + isolated["mixed-port"] + isolated["socks-port"], 0);
    assert.equal(receipt.dirMode, 0o700);
    assert.equal(receipt.fileMode, 0o600);
    assert.ok(!receipt.env.includes("CLASH_POST_UP"));
    assert.ok(receipt.calls.some((call) => call.includes("expected=204")));
    assert.ok(receipt.calls.includes(`/proxies/${encodeURIComponent("美国 S1")}`));
    assert.ok(isDead(receipt.pid));
    assert.deepEqual((await readdir(engine.root)).sort(), ["engine", "receipt.json"]);
  } finally { if (previous === undefined) delete process.env.CLASH_POST_UP; else process.env.CLASH_POST_UP = previous; await engine.close(); }
});

test("HTTPS probes run four at a time, preserve input order and reject unexpected status or zero delay", async () => {
  const engine = await fakeEngine();
  try {
    const names = ["正常 1", "WrongStatus", "正常 2", "Timeout", "正常 3", "Zero", "Failed", "正常 4", "正常 5", "正常 6"];
    const result = await pingNodeDelay(config(...names.map((name) => node(name))), names, { binaryPath: engine.binary, tempRoot: engine.root, resolve });
    assert.deepEqual(result.results.map(({ name }) => name), names);
    assert.equal(result.results[1].status, "unavailable");
    assert.match(result.results[1].error ?? "", /204/);
    assert.equal(result.results[3].status, "timeout");
    assert.equal(result.results[5].status, "unavailable");
    assert.equal(result.results[6].status, "unavailable");
    assert.equal((await eventually(engine.log)).maxConcurrent, 4);
  } finally { await engine.close(); }
});

test("unsafe file fields, unknown protocols, nested xhttp, reserved paths and private node servers are blocked", async () => {
  for (const fields of [
    { "certificate": "/etc/hosts" }, { "private-key": "/Users/me/private" }, { type: "ssh", "private-key": "secret" },
    { type: "vless", "xhttp-opts": { "download-settings": { server: "127.0.0.1" } } }, { "interface-name": "utun0" },
    { "routing-mark": 1 }, { "ws-opts": { path: "/okay", "private-key": "/secret" } },
    { name: "DIRECT" }, { plugin: "/bin/sh" }, { server: "127.0.0.1" },
  ]) assert.throws(() => safeDelayNode(node("unsafe", fields)));
  assert.doesNotThrow(() => safeDelayNode(node("safe", { type: "vless", uuid: "demo", network: "ws", "ws-opts": { path: "/transport", headers: { Host: "example.com" } }, "reality-opts": { "public-key": "public", "short-id": "aa" } })));
  const signal = new AbortController().signal;
  const prepared = await prepareDelayNodes(config(node("DNS private", { server: "example.com" })), ["DNS private"], async () => ["192.168.1.1"], signal);
  assert.equal(prepared.results.get("DNS private")?.status, "blocked");
  assert.equal(prepared.nodes.length, 0);
});

test("embedded dialer dependencies are retained and missing, group or circular dependencies are blocked", async () => {
  const signal = new AbortController().signal;
  const nodes = config(node("A", { "dialer-proxy": "B" }), node("B"), node("Missing", { "dialer-proxy": "group" }), node("Cycle", { "dialer-proxy": "Cycle" }));
  const prepared = await prepareDelayNodes(nodes, ["A", "Missing", "Cycle"], resolve, signal);
  assert.deepEqual(prepared.valid, ["A"]);
  assert.deepEqual(prepared.nodes.map(({ name }) => name), ["B", "A"]);
  assert.equal(prepared.results.get("Missing")?.status, "blocked");
  assert.equal(prepared.results.get("Cycle")?.status, "blocked");
  assert.equal(prepared.nodes[1]["dialer-proxy"], "B");
});

test("request cancellation and app shutdown terminate the engine and remove all secret files", async () => {
  for (const cancelAll of [false, true]) {
    const engine = await fakeEngine();
    const controller = new AbortController();
    try {
      const running = pingNodeDelay(config(node("Slow")), ["Slow"], { binaryPath: engine.binary, tempRoot: engine.root, resolve, signal: controller.signal });
      const rejected = assert.rejects(running);
      const receipt = await eventually(engine.log);
      if (cancelAll) cancelNodeDelays(); else controller.abort();
      await rejected;
      assert.ok(isDead(receipt.pid));
      assert.deepEqual((await readdir(engine.root)).sort(), ["engine", "receipt.json"]);
    } finally { await engine.close(); }
  }
});

test("dead engine and hung controller have bounded failure and no TCP fallback", async () => {
  const root = await mkdtemp("/tmp/studio-fail-test-");
  try {
    const result = await pingNodeDelay(config(node()), ["美国 S1"], { binaryPath: "/nonexistent/mihomo", tempRoot: root, resolve, bootTimeoutMs: 100 });
    assert.equal(result.results[0].status, "unavailable");
    assert.equal(result.results[0].latencyMs, undefined);
    assert.deepEqual(await readdir(root), []);
    const engine = await fakeEngine();
    try {
      const hung = await pingNodeDelay(config(node("Slow")), ["Slow"], { binaryPath: engine.binary, tempRoot: engine.root, resolve, requestTimeoutMs: 100 });
      assert.equal(hung.results[0].status, "timeout");
      assert.ok(isDead((await eventually(engine.log)).pid));
    } finally { await engine.close(); }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("invalid batches rejected before any kernel or network activity", async () => {
  await assert.rejects(pingNodeDelay(config(node()), []));
  await assert.rejects(pingNodeDelay(config(node()), ["A", "A"]));
  await assert.rejects(pingNodeDelay(config(node()), Array.from({ length: 11 }, (_, index) => String(index))));
  assert.equal(isolatedDelayConfig([], "/tmp/private.sock", "secret").profile["store-fake-ip"], false);
});

test("optional entry is applied only to requested exit clones; original config and existing chains stay intact", async () => {
  const engine = await fakeEngine();
  try {
    const original = config(node("Exit"), node("Entry"), node("Unselected"), node("Existing", { "dialer-proxy": "Entry" }));
    const before = structuredClone(original);
    const result = await pingNodeDelay(original, ["Exit", "Existing", "Entry"], { chainEntry: "Entry", binaryPath: engine.binary, tempRoot: engine.root, resolve });
    assert.equal(result.results[0].status, "ok");
    assert.equal(result.results[1].status, "blocked");
    assert.equal(result.results[2].status, "blocked");
    assert.deepEqual(original, before);
    const isolated = parse((await eventually(engine.log)).config) as SourceConfig;
    assert.deepEqual(isolated.proxies.map(({ name }) => name), ["Entry", "Exit"]);
    assert.equal(isolated.proxies[1]["dialer-proxy"], "Entry");
    const missing = await pingNodeDelay(original, ["Exit"], { chainEntry: "Absent", binaryPath: engine.binary, tempRoot: engine.root, resolve });
    assert.equal(missing.results[0].status, "blocked");
    await assert.rejects(pingNodeDelay(original, ["Exit"], { chainEntry: "invalid\nentry" }));
  } finally { await engine.close(); }
});
